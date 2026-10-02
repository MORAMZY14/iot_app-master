import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iot/auth_service.dart';

class TestUser implements User {
  TestUser(this.uid, {this.emailVerified = true});

  @override
  final String uid;
  @override
  final bool emailVerified;
  DateTime authTime = DateTime.now();
  bool deleted = false;
  Object? deleteError;
  Object? verificationError;

  @override
  String get email => 'owner@example.test';
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'id-token';
  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) async =>
      TestTokenResult(authTime);
  @override
  Future<void> updateDisplayName(String? name) async {}
  @override
  Future<void> sendEmailVerification([ActionCodeSettings? settings]) async {
    if (verificationError != null) throw verificationError!;
  }
  @override
  Future<void> delete() async {
    if (deleteError != null) throw deleteError!;
    deleted = true;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestTokenResult implements IdTokenResult {
  TestTokenResult(this.authTime);
  @override
  final DateTime authTime;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestCredential implements UserCredential {
  TestCredential(this.user);
  @override
  final User user;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestAuth implements FirebaseAuth {
  TestAuth(this.currentUser);
  @override
  User? currentUser;
  int accountsCreated = 0;
  int signOuts = 0;
  final changes = StreamController<User?>.broadcast();
  final newUser = TestUser('new-owner', emailVerified: false);

  @override
  Stream<User?> userChanges() => changes.stream;
  @override
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    accountsCreated++;
    currentUser = newUser;
    return TestCredential(newUser);
  }
  @override
  Future<void> signOut() async {
    signOuts++;
    currentUser = null;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late TestAuth auth;
  late List<http.Request> requests;

  setUp(() {
    auth = TestAuth(TestUser('owner'));
    requests = [];
  });
  tearDown(() async => auth.changes.close());

  AuthService service(FutureOr<http.Response> Function(http.Request) handle) =>
      AuthService(
        auth: auth,
        client: MockClient((request) async {
          requests.add(request);
          return handle(request);
        }),
        databaseUrl: 'https://database.example.test',
      );

  test('profile reads authenticate the current account', () async {
    final subject = service((request) => http.Response('{"esp32Code":"ESP-A"}', 200));
    final profile = await subject.getUserData('owner');
    expect(profile?['esp32Code'], 'ESP-A');
    expect(requests.single.url.path, '/users/owner.json');
    expect(requests.single.url.queryParameters['auth'], 'id-token');
  });

  test('another account UID is rejected before sending a database request', () async {
    final subject = service((request) => http.Response('{}', 200));
    await expectLater(subject.getUserData('other-owner'), throwsStateError);
    expect(requests, isEmpty);
  });

  test('permission failures remain errors instead of an empty profile', () async {
    final subject = service((request) => http.Response('{"error":"Permission denied"}', 401));
    await expectLater(subject.getUserData('owner'), throwsException);
  });

  test('network errors do not expose an ID token in user-visible messages', () async {
    final subject = service((request) => throw http.ClientException('Network failed', request.url));
    await expectLater(subject.getUserData('owner'), throwsA(
      isA<http.ClientException>()
        .having((error) => error.toString(), 'message', isNot(contains('id-token')))
        .having((error) => error.toString(), 'message', isNot(contains('auth='))),
    ));
  });

  test('a profile response from a previous account is discarded', () async {
    final pending = Completer<http.Response>();
    final subject = service((request) => pending.future);
    final profile = subject.getUserData('owner');
    await Future<void>.delayed(Duration.zero);
    auth.currentUser = TestUser('another-owner');
    pending.complete(http.Response('{"esp32Code":"ESP-A"}', 200));
    await expectLater(profile, throwsStateError);
  });

  test('profile providers discard cached codes when the signed-in account changes', () async {
    auth.currentUser = TestUser('alice');
    final subject = service((request) => http.Response(
      request.url.path.contains('/alice/') ? '"ESP-A"' : '"ESP-B"', 200,
    ));
    final container = ProviderContainer(overrides: [
      authServiceProvider.overrideWith((ref) async => subject),
    ]);
    addTearDown(container.dispose);
    final subscription = container.listen(userEsp32CodeProvider, (previous, next) {});
    addTearDown(subscription.close);
    expect(await container.read(userEsp32CodeProvider.future), 'ESP-A');
    await Future<void>.delayed(Duration.zero);
    auth.currentUser = TestUser('bob');
    auth.changes.add(auth.currentUser);
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(userEsp32CodeProvider.future), 'ESP-B');
    auth.currentUser = null;
    auth.changes.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(userEsp32CodeProvider.future), isNull);
  });

  test('malformed profile data is rejected instead of cast or silently hidden', () async {
    final subject = service((request) => http.Response('[1,2]', 200));
    await expectLater(subject.getUserData('owner'), throwsFormatException);
  });

  test('device codes cannot redirect a profile update to another database path', () async {
    final subject = service((request) => http.Response('{}', 200));
    await expectLater(subject.updateEsp32Code('owner', '../other'), throwsArgumentError);
    expect(requests, isEmpty);
  });

  test('switching an existing controller fails before any ownership or profile write', () async {
    final subject = service((request) => http.Response('"ESP-A"', 200));
    await expectLater(subject.updateEsp32Code('owner', 'ESP-B'), throwsStateError);
    expect(requests.length, 1);
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/users/owner/esp32Code.json');
  });

  test('saving the current controller code is idempotent', () async {
    final subject = service((request) => http.Response('"ESP-A"', 200));
    await subject.updateEsp32Code('owner', 'ESP-A');
    expect(requests.length, 1);
    expect(requests.single.method, 'GET');
  });

  test('offline controller verification does not create a Firebase account', () async {
    auth.currentUser = null;
    final subject = service((request) => http.Response('{"ip":"0.0.0.0"}', 200));
    await expectLater(subject.registerWithEmailPassword(
      email: 'new@example.test', password: 'secret password',
      displayName: 'New owner', esp32Code: 'ESP-A',
    ), throwsException);
    expect(auth.accountsCreated, 0);
  });

  test('registration cannot replace an existing controller owner', () async {
    auth.currentUser = null;
    final subject = service((request) {
      if (request.url.path.endsWith('/status.json')) return http.Response('{"ip":"192.168.1.20"}', 200);
      if (request.url.path.endsWith('/ownerUID.json')) return http.Response('"other-owner"', 200, headers: {'etag': '"claim-v1"'});
      fail('An owned controller must not receive a write');
    });
    await expectLater(subject.registerWithEmailPassword(
      email: 'new@example.test', password: 'secret password',
      displayName: 'New owner', esp32Code: 'ESP-A',
    ), throwsException);
    expect(auth.newUser.deleted, isTrue);
    expect(requests.every((request) => request.method == 'GET'), isTrue);
  });

  test('a racing controller claim cannot leave a profile or pending account', () async {
    auth.currentUser = null;
    final subject = service((request) {
      if (request.url.path.endsWith('/status.json')) return http.Response('{"ip":"192.168.1.20"}', 200);
      if (request.url.path.startsWith('/users/')) return http.Response(request.method == 'DELETE' ? 'null' : request.body, 200);
      if (request.method == 'GET') return http.Response('null', 200, headers: {'etag': 'null_etag'});
      expect(request.headers['if-match'], 'null_etag');
      return http.Response('"racing-owner"', 412);
    });
    await expectLater(subject.registerWithEmailPassword(
      email: 'new@example.test', password: 'secret password',
      displayName: 'New owner', esp32Code: 'ESP-A',
    ), throwsException);
    expect(auth.newUser.deleted, isTrue);
    expect(requests.any((request) => request.url.path.startsWith('/users/') && request.method == 'DELETE'), isTrue);
  });

  test('failed verification email never publishes a controller ownership claim', () async {
    auth.currentUser = null;
    auth.newUser.verificationError = FirebaseAuthException(code: 'too-many-requests');
    final subject = service((request) {
      if (request.url.path.endsWith('/status.json')) return http.Response('{"ip":"192.168.1.20"}', 200);
      if (request.method == 'GET') return http.Response('null', 200, headers: {'etag': 'null_etag'});
      return http.Response(request.method == 'DELETE' ? 'null' : request.body, 200);
    });
    await expectLater(subject.registerWithEmailPassword(
      email: 'new@example.test', password: 'secret password',
      displayName: 'New owner', esp32Code: 'ESP-A',
    ), throwsA(isA<FirebaseAuthException>()));
    expect(auth.newUser.deleted, isTrue);
    expect(requests.any((request) => request.url.path.endsWith('/ownerUID.json') && request.method != 'GET'), isFalse);
  });

  test('successful registration leaves a session available for verification resend', () async {
    auth.currentUser = null;
    final subject = service((request) {
      if (request.url.path.endsWith('/status.json')) return http.Response('{"ip":"192.168.1.20"}', 200);
      if (request.method == 'GET') return http.Response('null', 200, headers: {'etag': 'null_etag'});
      expect(request.url.queryParameters['auth'], 'id-token');
      return http.Response(request.body, 200);
    });
    final user = await subject.registerWithEmailPassword(
      email: 'new@example.test', password: 'secret password',
      displayName: 'New owner', esp32Code: 'ESP-A',
    );
    expect(user?.uid, 'new-owner');
    expect(auth.currentUser?.uid, 'new-owner');
    expect(auth.newUser.deleted, isFalse);
    await subject.resendVerificationEmail();
  });

  test('committed ownership with a lost reply preserves the registered account', () async {
    auth.currentUser = null;
    var committed = false;
    final subject = service((request) {
      if (request.url.path.endsWith('/status.json')) return http.Response('{"ip":"192.168.1.20"}', 200);
      if (request.url.path.endsWith('/ownerUID.json')) {
        if (request.method == 'PUT') {
          committed = true;
          throw http.ClientException('Lost response', request.url);
        }
        return http.Response(committed ? '"new-owner"' : 'null', 200, headers: {'etag': '"current"'});
      }
      return http.Response(request.body, 200);
    });
    final user = await subject.registerWithEmailPassword(
      email: 'new@example.test', password: 'secret password',
      displayName: 'New owner', esp32Code: 'ESP-A',
    );
    expect(user?.uid, 'new-owner');
    expect(auth.newUser.deleted, isFalse);
    expect(requests.any((request) => request.method == 'DELETE'), isFalse);
  });

  test('ambiguous ownership with unavailable reconciliation retains recovery state', () async {
    auth.currentUser = null;
    var attempted = false;
    final subject = service((request) {
      if (request.url.path.endsWith('/status.json')) return http.Response('{"ip":"192.168.1.20"}', 200);
      if (request.url.path.endsWith('/ownerUID.json')) {
        if (request.method == 'PUT') attempted = true;
        if (attempted) throw http.ClientException('Connection unavailable', request.url);
        return http.Response('null', 200, headers: {'etag': 'null_etag'});
      }
      return http.Response(request.body, 200);
    });
    await expectLater(subject.registerWithEmailPassword(
      email: 'new@example.test', password: 'secret password',
      displayName: 'New owner', esp32Code: 'ESP-A',
    ), throwsA(isA<ControllerLinkPendingException>()));
    expect(auth.currentUser?.uid, 'new-owner');
    expect(auth.newUser.deleted, isFalse);
    expect(requests.any((request) => request.method == 'DELETE'), isFalse);
  });

  test('stale sign-in fails account deletion before any data is removed', () async {
    final user = auth.currentUser! as TestUser;
    user.authTime = DateTime.now().subtract(const Duration(hours: 1));
    final subject = service((request) => http.Response('null', 200));
    await expectLater(subject.deleteAccount(), throwsA(isA<FirebaseAuthException>().having((error) => error.code, 'code', 'requires-recent-login')));
    expect(requests, isEmpty);
    expect(user.deleted, isFalse);
  });

  test('a linked account cannot be deleted while the firmware remains bound', () async {
    final user = auth.currentUser! as TestUser;
    final subject = service((request) => http.Response(
      '{"uid":"owner","esp32Code":"ESP-A"}', 200,
      headers: {'etag': '"current"'},
    ));
    await expectLater(subject.deleteAccount(), throwsStateError);
    expect(user.deleted, isFalse);
    expect(requests.every((request) => request.method == 'GET'), isTrue);
  });

  test('controller telemetry blocks erasure even when the profile code is missing', () async {
    final user = auth.currentUser! as TestUser;
    final subject = service((request) => http.Response(
      request.url.path.startsWith('/users/')
        ? '{"uid":"owner"}'
        : '{"status":{"uniqueCode":"ESP-A"}}',
      200, headers: {'etag': '"current"'},
    ));
    await expectLater(subject.deleteAccount(), throwsStateError);
    expect(user.deleted, isFalse);
    expect(requests.every((request) => request.method == 'GET'), isTrue);
  });

  test('failed Auth deletion restores the removed profile', () async {
    final user = auth.currentUser! as TestUser;
    user.deleteError = FirebaseAuthException(code: 'requires-recent-login');
    final state = <String, Object?>{
      '/users/owner.json': {'uid': 'owner'},
      '/smartHome/owner.json': {'lights': {'lamp': true}},
    };
    final subject = service((request) {
      final path = request.url.path;
      if (request.method == 'GET') return http.Response(jsonEncode(state[path]), 200, headers: {'etag': '"current"'});
      if (request.method == 'DELETE') {
        state[path] = null;
        return http.Response('null', 200);
      }
      if (request.method == 'PUT') {
        state[path] = jsonDecode(request.body);
        return http.Response(request.body, 200);
      }
      fail('Unexpected request: ${request.method} $path');
    });
    await expectLater(subject.deleteAccount(), throwsA(isA<FirebaseAuthException>()));
    expect(state['/users/owner.json'], {'uid': 'owner'});
    expect(state['/smartHome/owner.json'], {'lights': {'lamp': true}});
  });

  test('verification resend reports a missing session', () async {
    auth.currentUser = null;
    final subject = service((request) => http.Response('null', 200));
    await expectLater(subject.resendVerificationEmail(), throwsStateError);
  });
}
