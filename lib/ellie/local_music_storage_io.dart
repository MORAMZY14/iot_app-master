import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

/// Stores imported audio in the app sandbox so a temporary iOS/Android picker
/// URL is not lost after the document picker closes or the app restarts.
class LocalMusicStorage {
  LocalMusicStorage({Future<Directory> Function()? supportDirectory})
      : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  Future<String?> persist(PlatformFile selected) async {
    final support = await _supportDirectory();
    final directory = Directory(path_util.join(support.path, 'local_music'));
    await directory.create(recursive: true);

    final extension = path_util.extension(selected.name).toLowerCase();
    if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) return null;
    final destination = File(
      path_util.join(
        directory.path,
        'track_${DateTime.now().microsecondsSinceEpoch}$extension',
      ),
    );
    final temporary = File('${destination.path}.part');
    try {
      final sourcePath = selected.path;
      if (sourcePath != null && sourcePath.trim().isNotEmpty &&
          await File(sourcePath).exists()) {
        await File(sourcePath).copy(temporary.path);
      } else if (selected.bytes?.isNotEmpty == true) {
        await temporary.writeAsBytes(selected.bytes!, flush: true);
      } else if (selected.readStream != null) {
        final sink = temporary.openWrite();
        try {
          await sink.addStream(selected.readStream!);
        } finally {
          await sink.close();
        }
      } else {
        return null;
      }
      if (await temporary.length() == 0) return null;
      await temporary.rename(destination.path);
      return path_util.basename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<bool> exists(String path) async => await resolve(path) != null;

  Future<String?> resolve(String storedPath) async {
    if (storedPath.trim().isEmpty) return null;
    final direct = File(storedPath);
    if (path_util.isAbsolute(storedPath) && await direct.exists()) {
      return direct.path;
    }

    final support = await _supportDirectory();
    final candidate = File(
      path_util.join(
        support.path,
        'local_music',
        path_util.basename(storedPath),
      ),
    );
    return await candidate.exists() ? candidate.path : null;
  }

  Future<void> delete(String path) async {
    final resolved = await resolve(path);
    if (resolved == null) return;
    final support = await _supportDirectory();
    if (!path_util.isWithin(
      path_util.join(support.path, 'local_music'),
      resolved,
    )) return;
    await File(resolved).delete();
  }
}
