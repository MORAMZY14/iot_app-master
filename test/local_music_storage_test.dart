import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/ellie/local_music_storage_io.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory support;
  late LocalMusicStorage storage;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('assistant_music_test_');
    storage = LocalMusicStorage(supportDirectory: () async => support);
  });

  tearDown(() async {
    if (await support.exists()) await support.delete(recursive: true);
  });

  test('an interrupted picker stream leaves no partial imported audio', () async {
    Stream<List<int>> brokenAudio() async* {
      yield <int>[1, 2, 3];
      throw const FileSystemException('Picker source disappeared');
    }

    await expectLater(
      storage.persist(PlatformFile(
        name: 'Song.mp3',
        size: 20,
        readStream: brokenAudio(),
      )),
      throwsA(isA<FileSystemException>()),
    );
    final files = await Directory(path.join(support.path, 'local_music'))
        .list()
        .toList();
    expect(files, isEmpty);
  });

  test('empty copied files are rejected and the original is retained', () async {
    final original = File(path.join(support.path, 'empty.mp3'));
    await original.writeAsBytes(<int>[]);
    expect(
      await storage.persist(PlatformFile(
        name: 'empty.mp3',
        path: original.path,
        size: 0,
      )),
      isNull,
    );
    expect(await original.exists(), isTrue);
    expect(
      await Directory(path.join(support.path, 'local_music')).list().toList(),
      isEmpty,
    );
  });

  test('bytes and picker streams commit reopenable sandbox files', () async {
    for (final selected in <PlatformFile>[
      PlatformFile(
        name: 'Bytes.wav',
        size: 3,
        bytes: Uint8List.fromList(<int>[4, 5, 6]),
      ),
      PlatformFile(
        name: 'Stream.mp3',
        size: 3,
        readStream: Stream<List<int>>.value(<int>[4, 5, 6]),
      ),
    ]) {
      final stored = await storage.persist(selected);
      expect(stored, isNotNull);
      final resolved = await storage.resolve(stored!);
      expect(await File(resolved!).readAsBytes(), <int>[4, 5, 6]);
      expect(await File('$resolved.part').exists(), isFalse);
      await storage.delete(stored);
      expect(await storage.exists(stored), isFalse);
    }
    expect(await storage.resolve('   '), isNull);
  });

  test('legacy absolute paths can be played without deleting the original', () async {
    final original = File(path.join(support.path, 'original.mp3'));
    await original.writeAsBytes(<int>[7, 8, 9]);
    expect(await storage.resolve(original.path), original.path);
    await storage.delete(original.path);
    expect(await original.exists(), isTrue);
    final copied = await storage.persist(PlatformFile(
      name: 'original.mp3', path: original.path, size: 3,
    ));
    await storage.delete(copied!);
    expect(await storage.exists(copied), isFalse);
    expect(await original.readAsBytes(), <int>[7, 8, 9]);
  });
}
