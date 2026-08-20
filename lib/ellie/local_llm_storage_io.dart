import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

/// Copies a selected model into private application storage. Keeping our own
/// copy avoids temporary iOS document-picker URLs expiring after the app exits.
class LocalLlmStorage {
  static const String _directoryName = 'local_llm';

  Future<String?> persist(PlatformFile selected) async {
    if (path_util.extension(selected.name).toLowerCase() != '.task') {
      return null;
    }

    final support = await getApplicationSupportDirectory();
    final directory = Directory(path_util.join(support.path, _directoryName));
    await directory.create(recursive: true);
    final destination = File(path_util.join(
      directory.path,
      'assistant_${DateTime.now().microsecondsSinceEpoch}.task',
    ));

    final sourcePath = selected.path;
    if (sourcePath != null && sourcePath.trim().isNotEmpty) {
      final source = File(sourcePath);
      if (await source.exists()) {
        await source.copy(destination.path);
        return path_util.basename(destination.path);
      }
    }

    final bytes = selected.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      await destination.writeAsBytes(bytes, flush: true);
      return path_util.basename(destination.path);
    }

    final stream = selected.readStream;
    if (stream != null) {
      final sink = destination.openWrite();
      try {
        await sink.addStream(stream);
      } finally {
        await sink.close();
      }
      if (await destination.length() > 0) {
        return path_util.basename(destination.path);
      }
      await destination.delete();
    }
    return null;
  }

  Future<String?> resolve(String storedPath) async {
    if (storedPath.trim().isEmpty) return null;
    final direct = File(storedPath);
    if (path_util.isAbsolute(storedPath) && await direct.exists()) {
      return direct.path;
    }

    final support = await getApplicationSupportDirectory();
    final candidate = File(path_util.join(
      support.path,
      _directoryName,
      path_util.basename(storedPath),
    ));
    return await candidate.exists() ? candidate.path : null;
  }

  Future<void> delete(String storedPath) async {
    final resolved = await resolve(storedPath);
    if (resolved == null) return;
    final file = File(resolved);
    if (await file.exists()) await file.delete();
  }
}
