import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import 'app_constants.dart';
import 'auth_service.dart' show ensureFirebaseInitialized;

class FirebaseService {
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal() : _injectedAuth = null, _injectedDatabase = null;

  FirebaseService.withDependencies({
    required FirebaseAuth auth,
    required FirebaseDatabase database,
  }) : _injectedAuth = auth, _injectedDatabase = database;

  final FirebaseAuth? _injectedAuth;
  final FirebaseDatabase? _injectedDatabase;
  DatabaseReference? _root;

  FirebaseAuth get _auth => _injectedAuth ?? FirebaseAuth.instance;

  Future<DatabaseReference> _database() async {
    if (_root != null) return _root!;
    if (_injectedDatabase == null) await ensureFirebaseInitialized();
    return _root ??= (_injectedDatabase ?? FirebaseDatabase.instanceFor(
      app: Firebase.app(), databaseURL: AppConfig.databaseUrl,
    )).ref();
  }

  static void _validateKey(String key) {
    if (key.isEmpty || RegExp(r'[.#$\[\]/\x00-\x1f\x7f]').hasMatch(key)) {
      throw ArgumentError('Invalid Realtime Database key.');
    }
  }

  /// Each subscriber follows the current account, cancelling its previous
  /// home's database listener on sign-out or an account switch.
  Stream<DatabaseEvent> getData() {
    StreamSubscription<User?>? authSubscription;
    StreamSubscription<DatabaseEvent>? dataSubscription;
    late StreamController<DatabaseEvent> controller;
    var cancelled = false;
    var generation = 0;

    Future<void> switchUser(User? user, DatabaseReference root) async {
      final currentGeneration = ++generation;
      final previous = dataSubscription;
      dataSubscription = null;
      await previous?.cancel();
      if (cancelled || currentGeneration != generation || user == null) return;
      _validateKey(user.uid);
      dataSubscription = root.child('smartHome').child(user.uid).onValue.listen(
        (event) {
          if (!cancelled &&
              currentGeneration == generation &&
              _auth.currentUser?.uid == user.uid) {
            controller.add(event);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!cancelled && currentGeneration == generation) {
            controller.addError(error, stack);
          }
        },
      );
    }

    Future<void> start() async {
      try {
        final root = await _database();
        if (cancelled) return;
        authSubscription = _auth.authStateChanges().listen(
          (user) {
            unawaited(switchUser(user, root).catchError((Object error, StackTrace stack) {
              if (!cancelled) controller.addError(error, stack);
            }));
          },
          onError: (Object error, StackTrace stack) {
            if (!cancelled) controller.addError(error, stack);
          },
        );
      } catch (error, stack) {
        if (!cancelled) controller.addError(error, stack);
      }
    }

    controller = StreamController<DatabaseEvent>(
      onListen: () => unawaited(start()),
      onCancel: () async {
        cancelled = true;
        generation++;
        await authSubscription?.cancel();
        await dataSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  Future<void> setRoomLight(String room, bool value) async {
    _validateKey(room);
    if (_injectedAuth == null &&
        !Firebase.apps.any((app) => app.name == '[DEFAULT]')) {
      await ensureFirebaseInitialized();
    }
    final user = _auth.currentUser;
    if (user == null) throw StateError('User is not authenticated');
    _validateKey(user.uid);
    final root = await _database();
    if (_auth.currentUser?.uid != user.uid) {
      throw StateError('The account changed during the light update');
    }
    await root.child('smartHome').child(user.uid).child('lights').child(room).set(value);
  }
}
