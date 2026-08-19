import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

/// Stores imported audio in the app sandbox so a temporary iOS/Android picker
/// URL is not lost after the document picker closes or the app restarts.
class LocalMusicStorage {
  Future<String?> persist(PlatformFile selected) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(path_util.join(support.path, 'local_music'));
    await directory.create(recursive: true);

    final extension = path_util.extension(selected.name).toLowerCase();
    if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) return null;
    final destination = File(path_util.join(
      directory.path,
      'track_${DateTime.now().microsecondsSinceEpoch}$extension',
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

  Future<bool> exists(String path) async => await resolve(path) != null;

  Future<String?> resolve(String storedPath) async {
    final direct = File(storedPath);
    if (path_util.isAbsolute(storedPath) && await direct.exists()) {
      return direct.path;
    }

    final support = await getApplicationSupportDirectory();
    final candidate = File(path_util.join(
      support.path,
      'local_music',
      path_util.basename(storedPath),
    ));
    return await candidate.exists() ? candidate.path : null;
  }

  Future<void> delete(String path) async {
    final resolved = await resolve(path);
    if (resolved != null) await File(resolved).delete();
  }
}
