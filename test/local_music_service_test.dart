import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/ellie/ellie_language.dart';
import 'package:iot/ellie/local_music_service.dart';
import 'package:iot/ellie/local_music_storage.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PlayerFake extends Fake implements AudioPlayer {
  final states = StreamController<PlayerState>.broadcast();
  final loadingStarted = Completer<void>();
  Completer<void>? loadingGate;
  String? loadedPath;
  int playCalls = 0;
  int stopCalls = 0;

  @override
  bool playing = false;
  @override
  ProcessingState processingState = ProcessingState.ready;
  @override
  Stream<PlayerState> get playerStateStream => states.stream;

  Future<Duration?> _load(String path) async {
    if (!loadingStarted.isCompleted) loadingStarted.complete();
    if (loadingGate != null) await loadingGate!.future;
    loadedPath = path;
    processingState = ProcessingState.ready;
    return const Duration(minutes: 2);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #setFilePath:
        return _load(invocation.positionalArguments.first as String);
      case #play:
        playCalls++;
        playing = true;
        return Future<void>.value();
      case #pause:
        playing = false;
        return Future<void>.value();
      case #stop:
        stopCalls++;
        playing = false;
        return Future<void>.value();
      case #seek:
        processingState = ProcessingState.ready;
        return Future<void>.value();
      case #dispose:
        return states.close();
    }
    return super.noSuchMethod(invocation);
  }
}

class _StorageFake extends LocalMusicStorage {
  final files = <String>{};
  String? failImport;
  String? failDelete;
  bool unavailable = false;
  String? gatedImport;
  Completer<void>? importGate;
  final importStarted = Completer<void>();

  @override
  Future<String?> persist(PlatformFile selected) async {
    if (selected.name == failImport) throw StateError('Unreadable picker file');
    if (selected.name == gatedImport) {
      if (!importStarted.isCompleted) importStarted.complete();
      await importGate!.future;
    }
    files.add(selected.name);
    return selected.name;
  }

  @override
  Future<bool> exists(String path) async {
    if (unavailable) throw StateError('Storage temporarily unavailable');
    return files.contains(path);
  }

  @override
  Future<String?> resolve(String path) async =>
      files.contains(path) ? '/local/$path' : null;

  @override
  Future<void> delete(String path) async {
    if (path == failDelete) throw StateError('Audio file is temporarily locked');
    files.remove(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _PlayerFake player;
  late _StorageFake storage;
  late LocalMusicService service;
  var selected = <PlatformFile>[];
  const libraryKey = 'ellie_local_music_library_v1';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    player = _PlayerFake();
    storage = _StorageFake();
    selected = <PlatformFile>[];
    service = LocalMusicService.forTesting(
      player: player,
      storage: storage,
      configureSession: () async {},
      pickTracks: () async => FilePickerResult(selected),
    );
  });

  tearDown(() {
    service.dispose();
  });

  Future<void> importLibrary() async {
    selected = <PlatformFile>[
      PlatformFile(name: 'A.mp3', size: 1),
      PlatformFile(name: 'B.mp3', size: 1),
      PlatformFile(name: 'C.mp3', size: 1),
    ];
    expect(await service.importTracks(), 3);
  }

  test('deferred next keeps the chosen song when earlier entries are removed', () async {
    await importLibrary();
    final first = service.tracks.first;
    final next = service.tracks[1];
    await service.playTrack(first);
    final plan = await service.prepareCommand(
      const LocalMusicIntent(LocalMusicAction.next),
      language: EllieLanguage.english,
    );
    await service.removeTrack(first);
    await plan.afterReply!();
    expect(service.currentTrack?.path, next.path);
    expect(player.loadedPath, '/local/${next.path}');
  });

  test('a removed deferred song cannot be replaced by another index', () async {
    await importLibrary();
    await service.playTrack(service.tracks.first);
    final next = service.tracks[1];
    final plan = await service.prepareCommand(
      const LocalMusicIntent(LocalMusicAction.next),
      language: EllieLanguage.english,
    );
    await service.removeTrack(next);
    await expectLater(plan.afterReply!(), throwsStateError);
    expect(player.loadedPath, '/local/A.mp3');
    // A rejected deferred action must not poison subsequent player operations.
    await service.playTrack(service.tracks.last);
    expect(player.loadedPath, '/local/C.mp3');
  });

  test('resume selects the first saved song when none is selected', () async {
    await importLibrary();
    expect(service.currentTrack, isNull);
    final plan = await service.prepareCommand(
      const LocalMusicIntent(LocalMusicAction.resume),
      language: EllieLanguage.english,
    );
    await plan.afterReply!();
    expect(service.currentTrack?.path, 'A.mp3');
    expect(service.isPlaying, isTrue);
  });

  test('assistant completion respects a later explicit pause', () async {
    await importLibrary();
    await service.playTrack(service.tracks.first);
    expect(await service.pauseForAssistant(), isTrue);
    await service.pause();
    await service.resumeAfterAssistant(onlyIfPausedByAssistant: true);
    expect(service.isPlaying, isFalse);
    expect(player.playCalls, 1);
    await service.resumeAfterAssistant();
    expect(service.isPlaying, isTrue);
    expect(player.playCalls, 2);
  });

  test('removing a loading song waits for the player transition', () async {
    await importLibrary();
    final first = service.tracks.first;
    player.loadingGate = Completer<void>();
    final playing = service.playTrack(first);
    await player.loadingStarted.future;
    var removed = false;
    final removing = service.removeTrack(first).then((_) => removed = true);
    await Future<void>.delayed(Duration.zero);
    expect(removed, isFalse);
    expect(player.stopCalls, 0);
    player.loadingGate!.complete();
    await playing;
    await removing;
    expect(service.currentTrack, isNull);
    expect(service.tracks.map((track) => track.path), <String>['B.mp3', 'C.mp3']);
    expect(player.stopCalls, 1);
  });

  test('large audio copying does not block pause or reopen the picker', () async {
    await importLibrary();
    await service.playTrack(service.tracks.first);
    selected = <PlatformFile>[PlatformFile(name: 'D.mp3', size: 1000000)];
    storage.gatedImport = 'D.mp3';
    storage.importGate = Completer<void>();
    final importing = service.importTracks();
    await storage.importStarted.future;
    expect(await service.importTracks(), 0);
    await service.pause();
    expect(service.isPlaying, isFalse);
    storage.importGate!.complete();
    expect(await importing, 1);
    expect(service.tracks.last.path, 'D.mp3');
  });

  test('a paused completion event cannot restart the playlist', () async {
    await importLibrary();
    await service.playTrack(service.tracks.first);
    await service.pause();
    player.processingState = ProcessingState.completed;
    player.states.add(PlayerState(false, ProcessingState.completed));
    await Future<void>.delayed(Duration.zero);
    expect(player.loadedPath, '/local/A.mp3');
    expect(service.isPlaying, isFalse);
  });

  test('failed audio deletion retains a removable library entry', () async {
    await importLibrary();
    final first = service.tracks.first;
    await service.playTrack(first);
    storage.failDelete = first.path;
    await expectLater(service.removeTrack(first), throwsStateError);
    expect(service.tracks.first.path, first.path);
    expect(service.isPlaying, isFalse);
    storage.failDelete = null;
    await service.removeTrack(first);
    expect(service.tracks.map((track) => track.path), <String>['B.mp3', 'C.mp3']);
    expect(service.currentTrack, isNull);
  });

  test('successful imports are persisted before a later picker failure propagates', () async {
    selected = <PlatformFile>[
      PlatformFile(name: 'A.mp3', size: 1),
      PlatformFile(name: 'Broken.mp3', size: 1),
    ];
    storage.failImport = 'Broken.mp3';
    await expectLater(service.importTracks(), throwsStateError);
    expect(service.tracks.map((track) => track.path), <String>['A.mp3']);
    final encoded = (await SharedPreferences.getInstance()).getString(libraryKey);
    final saved = jsonDecode(encoded!) as List<dynamic>;
    expect(saved.single['path'], 'A.mp3');
  });

  test('a transient storage failure keeps preferences and allows initialization retry', () async {
    final encoded = jsonEncode(<Map<String, String>>[
      <String, String>{'title': 'A', 'path': 'A.mp3'},
    ]);
    SharedPreferences.setMockInitialValues(<String, Object>{libraryKey: encoded});
    storage.files.add('A.mp3');
    storage.unavailable = true;
    await expectLater(service.initialize(), throwsStateError);
    expect((await SharedPreferences.getInstance()).getString(libraryKey), encoded);
    storage.unavailable = false;
    await service.initialize();
    expect(service.tracks.map((track) => track.path), <String>['A.mp3']);
  });
}
