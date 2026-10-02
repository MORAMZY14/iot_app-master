import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'app_constants.dart';
import 'app_logger.dart';
import 'firebase_options.dart';

Future<void>? _firebaseInitialization;

Future<void> ensureFirebaseInitialized() async {
  // A named secondary app does not imply that the default app exists.
  if (Firebase.apps.any((app) => app.name == '[DEFAULT]')) return;
  final pending = _firebaseInitialization;
  if (pending != null) return pending;
  final initialization = Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  ).then<void>((_) {});
  _firebaseInitialization = initialization;
  try {
    await initialization;
  } finally {
    if (identical(_firebaseInitialization, initialization)) {
      _firebaseInitialization = null;
    }
  }
}

class _DatabaseSnapshot {
  const _DatabaseSnapshot(this.path, this.value, this.etag);
  final String path;
  final Object? value;
  final String etag;
}

class _ControllerClaimRejected implements Exception {
  @override
  String toString() => 'This ESP32 is linked to another account.';
}

class ControllerLinkPendingException implements Exception {
  @override
  String toString() => 'Your account was saved, but controller linking could not '
      'be confirmed. Verify your email, then sign in to retry. Your account has been preserved.';
}

class _AccountDatabaseClient extends http.BaseClient {
  _AccountDatabaseClient(this._inner);
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Firebase ID tokens must never follow a redirect to another host or be
    // exposed by ClientException.toString() in the login screen.
    request.followRedirects = false;
    try {
      return await _inner.send(request);
    } on http.ClientException {
      throw http.ClientException('The database connection is unavailable. Please retry.');
    }
  }

  @override
  void close() => _inner.close();
}

extension _AccountResponseDeadline on Future<http.Response> {
  Future<http.Response> accountResponse() async {
    try {
      return await timeout(AuthService._accountTimeout);
    } on http.ClientException {
      // Includes errors raised while reading a streamed response body.
      throw http.ClientException('The database connection is unavailable. Please retry.');
    }
  }
}

class AuthService {
  AuthService({FirebaseAuth? auth, http.Client? client, String? databaseUrl})
    : _auth = auth ?? FirebaseAuth.instance,
      _client = _AccountDatabaseClient(client ?? http.Client()),
      _ownsClient = client == null,
      databaseUrl = databaseUrl ?? AppConfig.databaseUrl;

  final FirebaseAuth _auth;
  final http.Client _client;
  final bool _ownsClient;
  final String databaseUrl;
  bool _registrationInProgress = false;

  // Account setup/deletion must not use the short local-control deadline.
  static const _accountTimeout = Duration(seconds: 10);
  static const _recentLoginWindow = Duration(minutes: 5);

  User? get currentUser => _auth.currentUser;
  Stream<User?> get userChanges => _auth.userChanges();

  void dispose() {
    if (_ownsClient) _client.close();
  }

  static String _validateKey(String value, String label) {
    if (value.isEmpty ||
        utf8.encode(value).length > 768 ||
        RegExp(r'[.#$\[\]/\x00-\x1f\x7f]').hasMatch(value)) {
      throw ArgumentError('Invalid $label.');
    }
    return value;
  }

  static String _controllerCode(String value) =>
      _validateKey(value.trim(), 'ESP32 code');

  Uri _databaseUri(String path, {String? token}) {
    final base = Uri.parse(databaseUrl);
    if (base.scheme != 'https' || base.userInfo.isNotEmpty) {
      throw StateError('Firebase database requests require an HTTPS endpoint.');
    }
    final parts = path.split('/');
    for (final part in parts) {
      _validateKey(part, 'database path');
    }
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((part) => part.isNotEmpty),
        ...parts.take(parts.length - 1),
        '${parts.last}.json',
      ],
      queryParameters: token == null ? null : {'auth': token},
    );
  }

  User _requireUser([String? uid]) {
    final user = currentUser;
    if (user == null || (uid != null && user.uid != uid)) {
      throw StateError('The requested account is not signed in.');
    }
    _validateKey(user.uid, 'user UID');
    return user;
  }

  /// Creates an authenticated REST URL for a bare Realtime Database path.
  /// Never log this URL: its query contains the short-lived Firebase ID token.
  Future<Uri> authenticatedDatabaseUri(String path, {String? uid}) async {
    final user = _requireUser(uid);
    final parts = path.split('/');
    if (parts.length > 1 &&
        (parts.first == 'users' || parts.first == 'smartHome') &&
        parts[1] != user.uid) {
      throw StateError('The requested account is not signed in.');
    }
    final token = await user.getIdToken().timeout(_accountTimeout);
    _requireUser(user.uid); // An account switch can occur during token refresh.
    if (token == null || token.isEmpty) {
      throw StateError('Firebase could not authenticate the database request.');
    }
    return _databaseUri(path, token: token);
  }

  void _requireSuccess(http.Response response, String operation) {
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception('Could not $operation (HTTP ${response.statusCode}).');
    }
  }

  Future<void> _verifyController(String code) async {
    final response = await _client.get(
      _databaseUri('esp_public/$code/status'),
      headers: const {'Cache-Control': 'no-cache'},
    ).accountResponse();
    _requireSuccess(response, 'verify the ESP32 code');
    final data = jsonDecode(response.body);
    final ip = data is Map ? data['ip'] : null;
    if (ip is! String ||
        ip.trim().isEmpty ||
        ip.trim() == '0.0.0.0' ||
        ip.trim() == 'BLE') {
      throw Exception('ESP32 is offline or not broadcasting. Please power it on.');
    }
  }

  Future<_DatabaseSnapshot> _snapshot(String path, String uid) async {
    final response = await _client.get(
      await authenticatedDatabaseUri(path, uid: uid),
      headers: const {'Cache-Control': 'no-cache', 'X-Firebase-ETag': 'true'},
    ).accountResponse();
    _requireSuccess(response, 'read account data');
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw StateError('Firebase did not provide a safe update version.');
    }
    return _DatabaseSnapshot(path, jsonDecode(response.body), etag);
  }

  Future<bool> _claimController(
    String code, String uid, {_DatabaseSnapshot? currentClaim}
  ) async {
    final claim = currentClaim ?? await _snapshot('esp_public/$code/ownerUID', uid);
    if (claim.value == uid) return false;
    if (claim.value != null) {
      throw _ControllerClaimRejected();
    }
    final response = await _client.put(
      await authenticatedDatabaseUri(claim.path, uid: uid),
      headers: {'Content-Type': 'application/json', 'If-Match': claim.etag},
      body: jsonEncode(uid),
    ).accountResponse();
    if (response.statusCode == 412) {
      throw _ControllerClaimRejected();
    }
    _requireSuccess(response, 'link the ESP32');
    return true;
  }

  Future<void> _restoreIfMissing(_DatabaseSnapshot snapshot, String uid) async {
    if (snapshot.value == null) return;
    final response = await _client.put(
      await authenticatedDatabaseUri(snapshot.path, uid: uid),
      headers: const {'Content-Type': 'application/json', 'If-Match': 'null_etag'},
      body: jsonEncode(snapshot.value),
    ).accountResponse();
    if (response.statusCode != 412) {
      _requireSuccess(response, 'restore account data');
    }
  }

  Future<User?> registerWithEmailPassword({
    required String email,
    required String password,
    required String displayName,
    required String esp32Code,
  }) async {
    final code = _controllerCode(esp32Code);
    if (_registrationInProgress || currentUser != null) {
      throw StateError('Finish the current sign-in before creating an account.');
    }
    _registrationInProgress = true;
    User? createdUser;
    bool claimAttempted = false;
    bool profileAttempted = false;
    try {
      await _verifyController(code);
      final result = await _auth.createUserWithEmailAndPassword(
        email: email.trim(), password: password,
      );
      final user = result.user;
      if (user == null) throw StateError('Firebase did not create the account.');
      createdUser = user;
      await user.updateDisplayName(displayName.trim());

      // Validate ownership first, but publish it only after account setup.
      // Firmware caches the owner in NVS as soon as the claim is visible.
      final claim = await _snapshot('esp_public/$code/ownerUID', user.uid);
      if (claim.value != null && claim.value != user.uid) {
        throw Exception('This ESP32 is already linked to another account.');
      }
      profileAttempted = true;
      final response = await _client.put(
        await authenticatedDatabaseUri('users/${user.uid}', uid: user.uid),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'uid': user.uid,
          'email': email.trim(),
          'displayName': displayName.trim(),
          'esp32Code': code,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'emailVerified': false,
        }),
      ).accountResponse();
      _requireSuccess(response, 'create the account profile');
      await user.sendEmailVerification();
      claimAttempted = true;
      await _claimController(code, user.uid, currentClaim: claim);
      // Keep this unverified session for the verification dialog's Resend.
      // The app's route gate must require emailVerified before home access.
      return user;
    } catch (error) {
      final user = createdUser;
      if (claimAttempted && user != null && error is! _ControllerClaimRejected) {
        // A failed/late response does not prove the conditional PUT failed.
        // Firmware may already have permanently cached this UID in NVS.
        // Reconcile success when possible, otherwise retain the account and
        // profile for recovery; never release a possibly committed owner.
        try {
          final claim = await _snapshot('esp_public/$code/ownerUID', user.uid);
          if (claim.value == user.uid && currentUser?.uid == user.uid) return user;
        } catch (_) {
          // An unavailable read is still an ambiguous ownership outcome.
        }
        throw ControllerLinkPendingException();
      }
      if (user != null && currentUser?.uid == user.uid) {
        if (profileAttempted) {
          try {
            final response = await _client.delete(
              await authenticatedDatabaseUri('users/${user.uid}', uid: user.uid),
            ).accountResponse();
            _requireSuccess(response, 'remove the incomplete profile');
          } catch (cleanupError) {
            logDebug('Registration profile cleanup failed (${cleanupError.runtimeType}).');
          }
        }
        try {
          await user.delete();
          await _auth.signOut();
        } catch (cleanupError) {
          logDebug('Registration account cleanup failed (${cleanupError.runtimeType}).');
        }
      }
      // ClientException may include the authenticated URL. Log its type only.
      logDebug('Registration failed (${error.runtimeType}).');
      rethrow;
    } finally {
      _registrationInProgress = false;
    }
  }

  Future<User?> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final result = await _auth.signInWithEmailAndPassword(
      email: email.trim(), password: password,
    );
    final user = result.user;
    if (user != null && !user.emailVerified) {
      await _auth.signOut();
      throw Exception('Please verify your email before signing in. Check your inbox.');
    }
    if (user != null) {
      // Recover an interrupted registration before opening device controls.
      // An already-owned claim is idempotent; another owner's claim rejects.
      final code = await getUserEsp32Code(user.uid);
      if (code != null) await _claimController(code, user.uid);
    }
    return user;
  }

  Future<void> signOut() => _auth.signOut();
  Future<void> resetPassword(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  Future<void> resendVerificationEmail() async {
    final user = _requireUser();
    if (!user.emailVerified) await user.sendEmailVerification();
  }

  Future<Map<String, dynamic>?> getUserData(String uid) async {
    final response = await _client.get(
      await authenticatedDatabaseUri('users/$uid', uid: uid),
      headers: const {'Cache-Control': 'no-cache'},
    ).accountResponse();
    _requireUser(uid);
    _requireSuccess(response, 'read the account profile');
    final data = jsonDecode(response.body);
    if (data == null) return null;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('The account profile has an invalid format.');
    }
    return data;
  }

  Future<void> updateEsp32Code(String uid, String newCode) async {
    _requireUser(uid);
    final code = _controllerCode(newCode);
    final oldCode = await getUserEsp32Code(uid);
    if (oldCode == code) return;
    if (oldCode != null && oldCode.isNotEmpty) {
      // Clearing a cloud claim does not clear the old ESP32's NVS binding.
      // It would keep uploading to and receiving commands from this UID.
      throw StateError(
        'Safely unbind the currently linked controller before switching ESP32s. '
        'Controller transfer is not available in this firmware.',
      );
    }
    await _verifyController(code);
    var claimed = false;
    try {
      claimed = await _claimController(code, uid);
      final response = await _client.patch(
        await authenticatedDatabaseUri('users/$uid', uid: uid),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'esp32Code': code}),
      ).accountResponse();
      _requireSuccess(response, 'update the ESP32 code');
    } catch (_) {
      // Keep ownership once published: cloud release cannot unbind NVS.
      if (claimed) throw ControllerLinkPendingException();
      rethrow;
    }
  }

  Future<String?> getUserEsp32Code(String uid) async {
    final response = await _client.get(
      await authenticatedDatabaseUri('users/$uid/esp32Code', uid: uid),
      headers: const {'Cache-Control': 'no-cache'},
    ).accountResponse();
    _requireUser(uid);
    _requireSuccess(response, 'read the ESP32 code');
    final code = jsonDecode(response.body);
    if (code == null) return null;
    if (code is! String) {
      throw const FormatException('The saved ESP32 code has an invalid format.');
    }
    return _controllerCode(code);
  }

  Future<void> deleteAccount({String? password}) async {
    final user = _requireUser();
    if (password != null) {
      final email = user.email;
      if (email == null) throw StateError('This account has no email address.');
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      );
    }
    // Reject a stale session before touching database data. Firebase still
    // performs its authoritative recent-login check in user.delete().
    final token = await user.getIdTokenResult(true).timeout(_accountTimeout);
    final authTime = token.authTime;
    if (authTime == null ||
        DateTime.now().difference(authTime) > _recentLoginWindow) {
      throw FirebaseAuthException(
        code: 'requires-recent-login',
        message: 'Please sign in again before deleting your account.',
      );
    }
    _requireUser(user.uid);

    final profile = await _snapshot('users/${user.uid}', user.uid);
    final profileData = profile.value;
    if (profileData != null && profileData is! Map) {
      throw const FormatException('The account profile has an invalid format.');
    }
    final profileCode = profileData is Map ? profileData['esp32Code'] : null;
    if (profileCode != null && profileCode is! String) {
      throw const FormatException('The saved ESP32 code has an invalid format.');
    }
    if (profileCode is String && profileCode.trim().isNotEmpty) {
      throw StateError(
        'Safely unbind the linked controller before deleting this account. '
        'Account erasure for linked controllers is not available in this firmware.',
      );
    }
    final home = await _snapshot('smartHome/${user.uid}', user.uid);
    final homeData = home.value;
    final status = homeData is Map ? homeData['status'] : null;
    final broadcastCode = status is Map ? status['uniqueCode'] : null;
    if (broadcastCode != null) {
      throw StateError(
        'This account still has controller telemetry. Safely unbind the '
        'controller before deleting the account.',
      );
    }
    final snapshots = [profile, home];

    final attempted = <_DatabaseSnapshot>[];
    try {
      for (final snapshot in snapshots) {
        if (snapshot.value == null) continue;
        attempted.add(snapshot); // Also compensate a lost DELETE response.
        final response = await _client.delete(
          await authenticatedDatabaseUri(snapshot.path, uid: user.uid),
          headers: {'If-Match': snapshot.etag},
        ).accountResponse();
        _requireSuccess(response, 'remove account data');
      }
      _requireUser(user.uid);
      await user.delete();
    } catch (_) {
      if (currentUser?.uid == user.uid) {
        for (final snapshot in attempted.reversed) {
          try {
            await _restoreIfMissing(snapshot, user.uid);
          } catch (restoreError) {
            logDebug('Account data restoration failed (${restoreError.runtimeType}).');
          }
        }
      }
      rethrow;
    }
  }
}

final firebaseInitializationProvider = FutureProvider<void>((ref) async {
  await ensureFirebaseInitialized();
});

final authServiceProvider = FutureProvider<AuthService>((ref) async {
  await ref.watch(firebaseInitializationProvider.future);
  final service = AuthService();
  ref.onDispose(service.dispose);
  return service;
});

final authUserProvider = StreamProvider<User?>((ref) async* {
  final service = await ref.watch(authServiceProvider.future);
  yield service.currentUser;
  yield* service.userChanges;
});

final userDataProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final user = await ref.watch(authUserProvider.future);
  if (user == null) return null;
  final service = await ref.watch(authServiceProvider.future);
  return service.getUserData(user.uid);
});

final userEsp32CodeProvider = FutureProvider<String?>((ref) async {
  final user = await ref.watch(authUserProvider.future);
  if (user == null) return null;
  final service = await ref.watch(authServiceProvider.future);
  return service.getUserEsp32Code(user.uid);
});
