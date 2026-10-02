import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/firebase_service.dart';

class ServiceUser implements User {
  ServiceUser(this.uid);
  @override
  final String uid;
  @override
  bool get emailVerified => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ServiceAuth implements FirebaseAuth {
  User? user;
  final changes = StreamController<User?>.broadcast();
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() async* {
    yield user;
    yield* changes.stream;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ServiceEvent implements DatabaseEvent {
  ServiceEvent(this.owner);
  final String owner;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ServiceDatabase implements FirebaseDatabase {
  final streams = <String, StreamController<DatabaseEvent>>{};
  final writes = <String, Object?>{};
  final cancelled = <String>[];

  StreamController<DatabaseEvent> streamFor(String path) => streams.putIfAbsent(
    path,
    () => StreamController<DatabaseEvent>.broadcast(onCancel: () => cancelled.add(path)),
  );
  @override
  DatabaseReference ref([String? path]) => ServiceReference(this, path ?? '');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ServiceReference implements DatabaseReference {
  ServiceReference(this.database, this.path);
  final ServiceDatabase database;
  final String path;
  @override
  DatabaseReference child(String value) => ServiceReference(
    database, path.isEmpty ? value : '$path/$value',
  );
  @override
  Stream<DatabaseEvent> get onValue => database.streamFor(path).stream;
  @override
  Future<void> set(Object? value) async {
    database.writes[path] = value;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('database listeners switch accounts and stop reading the previous home', () async {
    final auth = ServiceAuth()..user = ServiceUser('alice');
    final database = ServiceDatabase();
    final service = FirebaseService.withDependencies(auth: auth, database: database);
    final owners = <String>[];
    final subscription = service.getData().listen((event) => owners.add((event as ServiceEvent).owner));
    await Future<void>.delayed(Duration.zero);
    database.streamFor('smartHome/alice').add(ServiceEvent('alice'));
    await Future<void>.delayed(Duration.zero);
    auth.user = ServiceUser('bob');
    auth.changes.add(auth.user);
    await Future<void>.delayed(Duration.zero);
    database.streamFor('smartHome/alice').add(ServiceEvent('late-alice'));
    database.streamFor('smartHome/bob').add(ServiceEvent('bob'));
    await Future<void>.delayed(Duration.zero);
    expect(owners, ['alice', 'bob']);
    expect(database.cancelled, contains('smartHome/alice'));
    await subscription.cancel();
    expect(database.cancelled, contains('smartHome/bob'));
    await auth.changes.close();
    for (final stream in database.streams.values) {
      await stream.close();
    }
  });

  test('a light update cannot escape the current user path', () async {
    final auth = ServiceAuth()..user = ServiceUser('owner');
    final database = ServiceDatabase();
    final service = FirebaseService.withDependencies(auth: auth, database: database);
    await expectLater(service.setRoomLight('../other/lamp', true), throwsArgumentError);
    expect(database.writes, isEmpty);
    await service.setRoomLight('Living Room', true);
    expect(database.writes, {'smartHome/owner/lights/Living Room': true});
    auth.user = null;
    await expectLater(service.setRoomLight('Living Room', false), throwsStateError);
    expect(database.writes['smartHome/owner/lights/Living Room'], isTrue);
    await auth.changes.close();
  });
}
