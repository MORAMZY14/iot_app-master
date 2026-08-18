import 'ellie_language.dart';

class OfflineAssistantReply {
  const OfflineAssistantReply({
    required this.text,
    required this.language,
  });

  final String text;
  final EllieLanguage language;
}

/// Small, deterministic assistant brain that runs entirely inside Flutter.
/// Device commands are still delegated to the ESP32 before this fallback is
/// used. No network model, remote API, or cloud conversation is involved.
class OfflineAssistant {
  OfflineAssistant._();

  static OfflineAssistantReply replyTo(
    String input, {
    required String assistantName,
    required EllieLanguage language,
    DateTime? now,
  }) {
    final normalized = _normalize(input);
    final current = now ?? DateTime.now();

    if (_containsAny(normalized, const [
      'hello',
      'hi ',
      'hey',
      'good morning',
      'good evening',
      'مرحبا',
      'اهلا',
      'السلام عليكم',
      'صباح الخير',
      'مساء الخير',
    ])) {
      return _reply(
        language,
        english: 'Hello. I’m $assistantName, running locally on your home system.',
        arabic: 'أهلاً. أنا $assistantName، وأعمل محلياً داخل نظام المنزل.',
      );
    }

    if (_containsAny(normalized, const [
      'your name',
      'who are you',
      'what are you',
      'اسمك',
      'مين انت',
      'من انت',
    ])) {
      return _reply(
        language,
        english: 'My name is $assistantName. I work without OpenAI or a cloud assistant.',
        arabic: 'اسمي $assistantName. أعمل بدون أوبن أي آي أو مساعد سحابي.',
      );
    }

    if (_containsAny(normalized, const [
      'what time',
      'current time',
      'time is it',
      'الساعة كام',
      'كم الساعة',
      'الوقت',
    ])) {
      final hour = current.hour % 12 == 0 ? 12 : current.hour % 12;
      final minute = current.minute.toString().padLeft(2, '0');
      final suffix = current.hour < 12 ? 'AM' : 'PM';
      return _reply(
        language,
        english: 'It is $hour:$minute $suffix.',
        arabic: 'الساعة الآن $hour:$minute ${current.hour < 12 ? 'صباحاً' : 'مساءً'}.',
      );
    }

    if (_containsAny(normalized, const [
      'what date',
      'today date',
      'what day',
      'التاريخ',
      'النهارده كام',
      'اليوم كام',
    ])) {
      const englishMonths = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December',
      ];
      return _reply(
        language,
        english:
            'Today is ${englishMonths[current.month - 1]} ${current.day}, ${current.year}.',
        arabic: 'تاريخ اليوم ${current.day}/${current.month}/${current.year}.',
      );
    }

    if (_containsAny(normalized, const [
      'thank',
      'thanks',
      'شكرا',
      'متشكر',
    ])) {
      return _reply(
        language,
        english: 'You’re welcome.',
        arabic: 'العفو.',
      );
    }

    if (_containsAny(normalized, const [
      'help',
      'what can you do',
      'commands',
      'مساعدة',
      'تقدر تعمل ايه',
      'الأوامر',
      'الاوامر',
    ])) {
      return _reply(
        language,
        english:
            'I can control named rooms and devices through the ESP32, report local sensor information, and answer simple time, date, and help questions.',
        arabic:
            'أقدر أتحكم في الغرف والأجهزة عن طريق الـ ESP، وأعرض بيانات الحساسات، وأجيب عن أسئلة بسيطة مثل الوقت والتاريخ والمساعدة.',
      );
    }

    if (_containsAny(normalized, const [
      'are you online',
      'internet',
      'cloud',
      'openai',
      'open ai',
      'اونلاين',
      'انترنت',
      'السحابة',
    ])) {
      return _reply(
        language,
        english:
            'No cloud assistant is connected. My commands and replies run locally in Flutter and on the ESP32.',
        arabic:
            'لا يوجد مساعد سحابي متصل. الأوامر والردود تعمل محلياً داخل فلاتر والـ ESP.',
      );
    }

    return _reply(
      language,
      english:
          'I work locally and do not generate open-ended cloud answers. Try a room or device command, or ask for help, the time, or the date.',
      arabic:
          'أنا أعمل محلياً ولا أُنشئ إجابات سحابية مفتوحة. جرّبي أمر غرفة أو جهاز، أو اسألي عن المساعدة أو الوقت أو التاريخ.',
    );
  }

  static OfflineAssistantReply _reply(
    EllieLanguage language, {
    required String english,
    required String arabic,
  }) =>
      OfflineAssistantReply(
        text: EllieLanguageTools.pick(
          language,
          english: english,
          arabic: arabic,
        ),
        language: language,
      );

  static bool _containsAny(String source, List<String> phrases) =>
      phrases.any(source.contains);

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[\s,،.!?؟;؛:_\-]+'), ' ')
      .replaceAll('أ', 'ا')
      .replaceAll('إ', 'ا')
      .replaceAll('آ', 'ا')
      .replaceAll('ى', 'ي')
      .trim();
}
