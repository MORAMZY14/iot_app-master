import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

class LocalLlmStorage {
  static const _directoryName = 'local_llm';
  Future<String?> persist(PlatformFile selected) async {
    final extension = path_util.extension(selected.name).toLowerCase();
    if (!const {'.task', '.gguf'}.contains(extension)) return null;
    final support = await getApplicationSupportDirectory();
    final directory = Directory(path_util.join(support.path, _directoryName));
    await directory.create(recursive: true);
    final destination = File(
      path_util.join(
        directory.path,
        'assistant_${DateTime.now().microsecondsSinceEpoch}$extension',
      ),
    );
    final temporary = File('${destination.path}.part');
    try {
      if (selected.path != null && await File(selected.path!).exists()) {
        await File(selected.path!).copy(temporary.path);
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
      if (extension == '.gguf') {
        final handle = await temporary.open();
        try {
          if (String.fromCharCodes(await handle.read(4)) != 'GGUF')
            throw const FormatException(
              'This is not a GGUF model. Renaming a file does not convert it.',
            );
        } finally {
          await handle.close();
        }
      }
      await temporary.rename(destination.path);
      return path_util.basename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<String?> resolve(String storedPath) async {
    if (storedPath.trim().isEmpty) return null;
    final direct = File(storedPath);
    if (path_util.isAbsolute(storedPath) && await direct.exists())
      return direct.path;
    final support = await getApplicationSupportDirectory();
    final candidate = File(
      path_util.join(
        support.path,
        _directoryName,
        path_util.basename(storedPath),
      ),
    );
    return await candidate.exists() ? candidate.path : null;
  }

  Future<void> delete(String storedPath) async {
    final resolved = await resolve(storedPath);
    if (resolved != null && await File(resolved).exists())
      await File(resolved).delete();
  }
}
