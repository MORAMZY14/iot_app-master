import 'package:flutter_test/flutter_test.dart';
import 'package:iot/assistant_identity.dart';
import 'package:iot/ellie/ellie_language.dart';
import 'package:iot/ellie/local_command_proposal_guard.dart';
import 'package:iot/ellie/local_llm_service.dart';
import 'package:iot/ellie/local_music_service.dart';
import 'package:iot/ellie/offline_assistant.dart';

void main() {
  test('assistant names are compacted and validated', () {
    expect(compactAssistantName('  Nova   Home  '), 'Nova Home');
    expect(validateAssistantName('Nova'), isNull);
    expect(validateAssistantName('N'), isNotNull);
    expect(validateAssistantName('bad/name'), isNotNull);
  });

  test('invalid or missing names fall back to Ellie', () {
    expect(normalizedAssistantName(null), defaultAssistantName);
    expect(normalizedAssistantName(''), defaultAssistantName);
    expect(normalizedAssistantName('  Luna  '), 'Luna');
  });

  test('offline assistant answers without a remote model', () {
    final greeting = OfflineAssistant.replyTo(
      'Hello Nova',
      assistantName: 'Nova',
      language: EllieLanguage.english,
    );
    expect(greeting.text, contains('Nova'));
    expect(greeting.text, contains('locally'));

    final fallback = OfflineAssistant.replyTo(
      'Write a long essay',
      assistantName: 'Nova',
      language: EllieLanguage.english,
    );
    expect(fallback.text, contains('work locally'));
    expect(fallback.text, contains('local music command'));
  });

  test('offline assistant supports Arabic and deterministic time', () {
    final reply = OfflineAssistant.replyTo(
      'الساعة كام',
      assistantName: 'نور',
      language: EllieLanguage.arabic,
      now: DateTime(2026, 8, 18, 21, 7),
    );
    expect(reply.text, contains('9:07'));
    expect(reply.language, EllieLanguage.arabic);
  });

  test('local music parser selects a named offline song', () {
    final intent = LocalMusicIntentParser.parse(
      'Jarvis, can you play Blinding Lights?',
      assistantName: 'Jarvis',
    );
    expect(intent?.action, LocalMusicAction.play);
    expect(intent?.requestedTitle, 'blinding lights');
  });

  test('local music parser handles bilingual transport commands', () {
    final pause = LocalMusicIntentParser.parse(
      'Jarvis pause the music',
      assistantName: 'Jarvis',
    );
    final arabic = LocalMusicIntentParser.parse(
      'يا نور شغلي أغنية حبيبي',
      assistantName: 'نور',
    );
    expect(pause?.action, LocalMusicAction.pause);
    expect(arabic?.action, LocalMusicAction.play);
    expect(arabic?.requestedTitle, 'حبيبي');

    final turnOn = LocalMusicIntentParser.parse(
      'Jarvis turn on music',
      assistantName: 'Jarvis',
    );
    expect(turnOn?.action, LocalMusicAction.play);
    expect(turnOn?.requestedTitle, isNull);
  });

  test('local model envelope extracts a safe device proposal', () {
    final envelope = LocalLlmEnvelope.parse(
      '```json\n'
      '{"reply":"Checking both devices.",'
      '"device_command":"turn off TV and Desk Lamp"}'
      '\n```',
      allowDeviceCommand: true,
    );
    expect(envelope.reply, 'Checking both devices.');
    expect(envelope.deviceCommand, 'turn off TV and Desk Lamp');
  });

  test('conversation output can never become a device command', () {
    final envelope = LocalLlmEnvelope.parse(
      '{"reply":"Let us talk.","device_command":"turn on all devices"}',
      allowDeviceCommand: false,
    );
    expect(envelope.reply, 'Let us talk.');
    expect(envelope.deviceCommand, isNull);
  });

  test('unsafe model actions are discarded before ESP32 validation', () {
    final envelope = LocalLlmEnvelope.parse(
      '{"reply":"I need more detail.","device_command":"erase everything"}',
      allowDeviceCommand: true,
    );
    expect(envelope.deviceCommand, isNull);
  });

  test('model command guard preserves direction and named-device scope', () {
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'Please power off just the TV and Desk Lamp',
        'turn off TV and Desk Lamp',
      ),
      isTrue,
    );
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'Turn off the TV',
        'turn off all devices',
      ),
      isFalse,
    );
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'Turn off the TV',
        'turn on TV',
      ),
      isFalse,
    );
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'Turn off the TV',
        'turn off TV and Desk Lamp',
      ),
      isFalse,
    );
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'اطفي التلفزيون ومروحة المكتب بس',
        'اطفي التلفزيون ومروحة المكتب',
      ),
      isTrue,
    );
  });
}
