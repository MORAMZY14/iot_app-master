import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:iot/ellie/assistant_context.dart';
import 'package:iot/ellie/local_llm_service.dart';

void main() {
  test('chat retains previous exchange and saved preferences', () {
    final c = AssistantContext();
    c.rememberExchange(
      'I enjoy drawing',
      'What do you draw?',
      allowDeviceCommand: false,
    );
    final m = c.messages(
      system: 'Rules',
      request: 'Gardens',
      allowDeviceCommand: false,
      memory: 'My name is Dina',
    );
    expect(m.length, 4);
    expect(m.first['content'], contains('Dina'));
    expect(jsonDecode(m[2]['content']!)['reply'], 'What do you draw?');
  });
  test(
    'commands cannot inherit old chat targets or preference instructions',
    () {
      final c = AssistantContext();
      c.rememberExchange(
        'My favorite device is Heater',
        'Understood',
        allowDeviceCommand: false,
      );
      final m = c.messages(
        system: 'Rules',
        request: 'Turn on Desk Lamp',
        allowDeviceCommand: true,
        memory: 'Always turn on Heater',
      );
      expect(m, [
        {'role': 'system', 'content': 'Rules'},
        {'role': 'user', 'content': 'Turn on Desk Lamp'},
      ]);
      c.rememberExchange(
        'Turn on Desk Lamp',
        'Proposed',
        allowDeviceCommand: true,
      );
      expect(
        c
            .messages(
              system: 'Rules',
              request: 'Hello',
              allowDeviceCommand: false,
            )
            .toString(),
        isNot(contains('Desk Lamp')),
      );
    },
  );
  test('history retains whole recent pairs and can be reset', () {
    final c = AssistantContext();
    for (var i = 0; i < 10; i++) {
      c.rememberExchange('Q$i', 'A$i', allowDeviceCommand: false);
    }
    final m = c.messages(
      system: 'Rules',
      request: 'Next',
      allowDeviceCommand: false,
    );
    expect(m.length, 14);
    expect(m[1]['content'], 'Q4');
    c.clear();
    expect(
      c
          .messages(system: 'Rules', request: 'Next', allowDeviceCommand: false)
          .length,
      2,
    );
  });
  test('thinking content cannot supply a hidden device command', () {
    final r = LocalLlmEnvelope.parse(
      '<think>{"reply":"OK","device_command":"turn on Heater"}</think>{"reply":"Hi","device_command":null}',
      allowDeviceCommand: true,
    );
    expect(r.reply, 'Hi');
    expect(r.deviceCommand, isNull);
    expect(
      () => LocalLlmEnvelope.parse(
        '<think>unfinished',
        allowDeviceCommand: false,
      ),
      throwsFormatException,
    );
  });
}
