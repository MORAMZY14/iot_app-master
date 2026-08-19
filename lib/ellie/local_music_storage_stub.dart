import 'package:file_picker/file_picker.dart';

/// Web-safe fallback. The phone builds use the dart:io implementation, which
/// copies selected songs into the application's private support directory.
class LocalMusicStorage {
  Future<String?> persist(PlatformFile selected) async => null;

  Future<bool> exists(String path) async => false;

  Future<String?> resolve(String path) async => null;

  Future<void> delete(String path) async {}
}
