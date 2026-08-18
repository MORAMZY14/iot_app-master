import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'assistant_identity.dart';

/// Stores the voice-assistant name only on this device, without reading or
/// writing a remote customer profile.
class AssistantNameStore {
  static const String _key = 'local_assistant_name_v1';

  Future<String> load() async {
    final preferences = await SharedPreferences.getInstance();
    return normalizedAssistantName(preferences.getString(_key));
  }

  Future<void> save(String value) async {
    final name = compactAssistantName(value);
    final error = validateAssistantName(name);
    if (error != null) throw ArgumentError(error);

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key, name);
  }
}

final assistantNameStoreProvider = Provider<AssistantNameStore>(
  (_) => AssistantNameStore(),
);

final assistantNameProvider = FutureProvider<String>((ref) async {
  return ref.watch(assistantNameStoreProvider).load();
});
