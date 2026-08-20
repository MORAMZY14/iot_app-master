import 'package:file_picker/file_picker.dart';

/// Browser-safe fallback. This project imports mobile `.task` models only on
/// Android and iOS; browsers cannot reopen an arbitrary local file path.
class LocalLlmStorage {
  Future<String?> persist(PlatformFile selected) async => null;

  Future<String?> resolve(String storedPath) async => null;

  Future<void> delete(String storedPath) async {}
}
