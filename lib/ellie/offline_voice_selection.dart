/// Android flutter_tts reports network_required as "0"/"1". Some engines
/// expose a boolean instead. Unknown capability never counts as offline.
Map<String, String>? selectOfflineVoice(
    Iterable<dynamic> voices, String locale) {
  final requested = locale.toLowerCase().replaceAll('_', '-');
  final prefix = requested.split('-').first;
  Map<String, String>? fallback;
  for (final voice in voices.whereType<Map>()) {
    final network = voice['network_required']?.toString();
    final name = voice['name']?.toString();
    final installed = voice['locale']?.toString();
    if ((network != '0' && network != 'false') ||
        name == null ||
        installed == null) continue;
    final normalized = installed.toLowerCase().replaceAll('_', '-');
    if (normalized.split('-').first != prefix) continue;
    final candidate = {'name': name, 'locale': installed};
    if (normalized == requested) return candidate;
    fallback ??= candidate;
  }
  return fallback;
}
