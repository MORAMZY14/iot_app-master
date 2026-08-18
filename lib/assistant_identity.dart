const String defaultAssistantName = 'Ellie';

String compactAssistantName(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

String? validateAssistantName(String value) {
  final name = compactAssistantName(value);
  if (name.length < 2) return 'Use at least 2 characters.';
  if (name.length > 24) return 'Use no more than 24 characters.';
  final supportedName = RegExp(
    r"^[\p{L}\p{M}\p{N}][\p{L}\p{M}\p{N} '\u2019-]*$",
    unicode: true,
  );
  if (!supportedName.hasMatch(name)) {
    return 'Use letters, numbers, spaces, apostrophes, or hyphens only.';
  }
  return null;
}

String normalizedAssistantName(Object? value) {
  final name = compactAssistantName(value?.toString() ?? '');
  return validateAssistantName(name) == null ? name : defaultAssistantName;
}
