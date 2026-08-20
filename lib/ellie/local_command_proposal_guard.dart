/// Conservative boundary between generated language and real home control.
/// It rejects direction changes, widened "all devices" scope, and target words
/// that were not present in the user's original request.
class LocalCommandProposalGuard {
  LocalCommandProposalGuard._();

  static bool preservesUserScope(String original, String proposed) {
    final originalDirection = _firstPowerDirection(original);
    final proposedDirection = _firstPowerDirection(proposed);
    if (originalDirection == null || proposedDirection != originalDirection) {
      return false;
    }

    final originalAll = _hasAllScope(original);
    final proposedAll = _hasAllScope(proposed);
    if (originalAll != proposedAll) return false;

    final originalTokens = _scopeTokens(original);
    final proposedTokens = _scopeTokens(proposed);
    if (originalAll && proposedTokens.isEmpty) return true;
    if (proposedTokens.isEmpty) return false;
    return proposedTokens.every(originalTokens.contains);
  }

  static String? _firstPowerDirection(String text) {
    final normalized = text.toLowerCase();
    final matches = <({int index, int end, String direction})>[];
    for (final match in RegExp(
      r'\b(turn|switch|power)\b.{0,100}?\boff\b|\bdeactivate\b|'
      r'\bshut\s+down\b|'
      r'(اطف|اطفي|اقفل|اقفلي|اغلق|اطفاء)',
    ).allMatches(normalized)) {
      matches.add((index: match.start, end: match.end, direction: 'off'));
    }
    for (final match in RegExp(
      r'\b(turn|switch|power)\b.{0,100}?\bon\b|\bactivate\b|'
      r'\bstart\s+up\b|'
      r'(شغل|شغلي|افتح|افتحي|تشغيل)',
    ).allMatches(normalized)) {
      matches.add((index: match.start, end: match.end, direction: 'on'));
    }
    if (matches.isEmpty) return null;
    matches.sort((left, right) {
      final byStart = left.index.compareTo(right.index);
      return byStart != 0 ? byStart : left.end.compareTo(right.end);
    });
    return matches.first.direction;
  }

  static bool _hasAllScope(String text) => RegExp(
        r'\b(all|everything|every device|whole room)\b|(كل|جميع)',
      ).hasMatch(text.toLowerCase());

  static Set<String> _scopeTokens(String text) {
    const ignored = <String>{
      'a', 'an', 'the', 'and', 'but', 'please', 'can', 'could', 'would',
      'you', 'just', 'only', 'turn', 'switch', 'power', 'on', 'off',
      'activate', 'deactivate', 'shut', 'down', 'start', 'up', 'leave',
      'all', 'everything', 'every', 'whole', 'device', 'devices', 'room',
      'rooms', 'to', 'my', 'in', 'of', 'is', 'are',
      'من', 'لو', 'سمحت', 'بس', 'فقط', 'و', 'ثم', 'شغل', 'شغلي', 'افتح',
      'افتحي', 'اطف', 'اطفي', 'اقفل', 'اقفلي', 'اغلق', 'تشغيل', 'اطفاء',
      'كل', 'جميع', 'الجهاز', 'الاجهزة', 'الأجهزة', 'الغرفة', 'الاوضة',
    };
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u0600-\u06ff]+'), ' ')
        .split(' ')
        .where((token) => token.isNotEmpty && !ignored.contains(token))
        .toSet();
  }
}
