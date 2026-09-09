import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

Future<File> _file(String key) async {
  final root = await getApplicationSupportDirectory();
  final folder = Directory('${root.path}/room_photos');
  await folder.create(recursive: true);
  return File('${folder.path}/$key.jpg');
}

Future<Uint8List?> loadPhoto(String key) async {
  final file = await _file(key);
  return await file.exists() ? file.readAsBytes() : null;
}

Future<bool> savePhoto(String key, Uint8List bytes) async {
  final target = await _file(key);
  final staging = File('${target.path}.partial');
  await staging.writeAsBytes(bytes, flush: true);
  await staging.rename(target.path);
  return true;
}

Future<void> removePhoto(String key) async {
  final file = await _file(key);
  if (await file.exists()) await file.delete();
}
