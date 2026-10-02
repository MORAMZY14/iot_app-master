/// Conservative boundary between generated language and real home control.
/// A model may normalize an action, but must retain every target qualifier in
/// its original order. Mixed actions and exclusions need deterministic parsing.
class LocalCommandProposalGuard {
  LocalCommandProposalGuard._();

  static bool preservesUserScope(
    String original,
    String proposed, {
    String? assistantName,
  }) {
    if (_hasExclusion(original) || _hasExclusion(proposed)) return false;
    final originalDirection = _powerDirection(original);
    final proposedDirection = _powerDirection(proposed);
    if (originalDirection == null || proposedDirection != originalDirection) {
      return false;
    }

    final originalAll = _hasAllScope(original);
    final proposedAll = _hasAllScope(proposed);
    if (originalAll != proposedAll) return false;

    final originalTokens = _scopeTokens(
      _withoutWakeWord(original, assistantName),
    );
    final proposedTokens = _scopeTokens(proposed);
    if (originalTokens.isEmpty || proposedTokens.isEmpty) {
      return originalAll && originalTokens.isEmpty && proposedTokens.isEmpty;
    }
    if (originalTokens.length != proposedTokens.length) return false;
    for (var index = 0; index < originalTokens.length; index++) {
      if (originalTokens[index] != proposedTokens[index]) return false;
    }
    return true;
  }

  static String? _powerDirection(String text) {
    final normalized = _normalize(text);
    final directions = <String>{};
    if (RegExp(
      r'\b(turn|switch|power)\b.{0,100}?\boff\b|\bdeactivate\b|'
      r'\bshut\s+down\b|'
      r'(اطف|اطفي|اقفل|اقفلي|اغلق|اطفاء)',
    ).hasMatch(normalized)) {
      directions.add('off');
    }
    if (RegExp(
      r'\b(turn|switch|power)\b.{0,100}?\bon\b|\bactivate\b|'
      r'\bstart\s+up\b|'
      r'(شغل|شغلي|افتح|افتحي|تشغيل)',
    ).hasMatch(normalized)) {
      directions.add('on');
    }
    return directions.length == 1 ? directions.single : null;
  }

  static bool _hasExclusion(String text) => RegExp(
        r"\b(not|never|except|excluding|unless|without|leave|keep|but|dont|don't)\b|"
        r'(?:^|\s)(لا|ليس|ليست|بدون|الا|عدا|باستثناء|متشغلش|متطفيش)(?=\s|$)',
      ).hasMatch(_normalize(text));

  static bool _hasAllScope(String text) => RegExp(
        r'\b(all|everything|every device|whole room)\b|(كل|جميع)',
      ).hasMatch(_normalize(text));

  static String _withoutWakeWord(String text, String? assistantName) {
    final normalized = _normalize(text);
    if (assistantName == null || assistantName.trim().isEmpty) return normalized;
    return normalized.replaceFirst(
      RegExp(
        '^(?:(?:hey|please|يا)\\s+)*${RegExp.escape(_normalize(assistantName))}(?=\\s|\$)',
      ),
      ' ',
    );
  }

  static List<String> _scopeTokens(String text) {
    const ignored = <String>{
      'a',
      'an',
      'the',
      'and',
      'but',
      'please',
      'can',
      'could',
      'would',
      'you',
      'just',
      'only',
      'all',
      'everything',
      'every',
      'whole',
      'to',
      'my',
      'in',
      'of',
      'is',
      'are',
      'من',
      'لو',
      'سمحت',
      'بس',
      'فقط',
      'و',
      'ثم',
      'كل',
      'جميع',
    };
    return _normalize(text)
        .replaceAll(RegExp(r'\b(turn|switch|power)\s+(on|off)\b'), ' ')
        .replaceAllMapped(
          RegExp(r'\b(turn|switch|power)\s+(.+?)\s+(on|off)\b'),
          (match) => ' ${match.group(2)} ',
        )
        .replaceAll(RegExp(r'\b(activate|deactivate|shut down|start up)\b'), ' ')
        .replaceAll(
          RegExp(
            r'(?:^|\s)(شغل|شغلي|افتح|افتحي|اطف|اطفي|اطفئ|اقفل|اقفلي|اغلق|تشغيل|اطفاء)(?=\s|$)',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[^a-z0-9\u0600-\u06ff]+'), ' ')
        .split(' ')
        .where((token) => token.isNotEmpty && !ignored.contains(token))
        .toList();
  }

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[\u064b-\u065f\u0670\u0640]'), '')
      .replaceAll('أ', 'ا')
      .replaceAll('إ', 'ا')
      .replaceAll('آ', 'ا')
      .replaceAll('ى', 'ي');
}
