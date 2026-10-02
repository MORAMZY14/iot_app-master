import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/ellie/local_llm_storage_io.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory support;
  late LocalLlmStorage storage;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('assistant_model_test_');
    storage = LocalLlmStorage(supportDirectory: () async => support);
  });

  tearDown(() async {
    if (await support.exists()) await support.delete(recursive: true);
  });

  test('a renamed non-GGUF file is rejected without leaving a model copy', () async {
    await expectLater(
      storage.persist(PlatformFile(
        name: 'not-a-model.gguf', size: 4,
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      )),
      throwsFormatException,
    );
    expect(await Directory(path.join(support.path, 'local_llm')).list().toList(),
        isEmpty);
  });

  test('GGUF and Gemma files retain separate supported extensions', () async {
    for (final name in <String>['Qwen.GGUF', 'Gemma.task']) {
      final stored = await storage.persist(PlatformFile(
        name: name, size: 8,
        bytes: Uint8List.fromList(<int>[71, 71, 85, 70, 1, 2, 3, 4]),
      ));
      expect(path.extension(stored!), path.extension(name).toLowerCase());
      expect(await storage.resolve(stored), isNotNull);
      await storage.delete(stored);
      expect(await storage.resolve(stored), isNull);
    }
  });

  test('legacy model loading cannot delete a file outside the model directory', () async {
    final original = File(path.join(support.path, 'original.task'));
    await original.writeAsBytes(<int>[1, 2, 3]);
    expect(await storage.resolve(original.path), original.path);
    await storage.delete(original.path);
    expect(await original.readAsBytes(), <int>[1, 2, 3]);
  });
}
