// This diagnostic deliberately prints replies and timings.
// ignore_for_file: avoid_print, avoid_relative_lib_imports
import 'dart:convert';
import '../lib/ellie/gguf_local_engine.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Usage: dart run tool/smoke_gguf.dart /path/to/model.gguf');
  }
  final engine = GgufLocalEngine();
  final timer = Stopwatch()..start();
  try {
    await engine.load(args.single);
    print('Loaded model in ${timer.elapsedMilliseconds} ms.');
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': 'You are a friendly English/Arabic assistant. Return one JSON object with reply and device_command. device_command must be null. Keep replies under two sentences. User-saved preference: my name is Dina.'},
      {'role': 'user', 'content': jsonEncode({'language': 'English', 'allow_device_command': false, 'user_text': 'Hi! What is my name?'})},
    ];
    for (var turn = 0; turn < 2; turn++) {
      timer.reset();
      final raw = await engine.generate(messages, allowDeviceCommand: false);
      final result = jsonDecode(raw) as Map<String, dynamic>;
      if (result['reply'] is! String || (result['reply'] as String).trim().isEmpty || result['device_command'] != null) {
        throw StateError('Invalid conversational response: $raw');
      }
      print('Turn ${turn + 1}, ${timer.elapsedMilliseconds} ms: $raw');
      messages.add({'role': 'assistant', 'content': raw});
      if (turn == 0) {
        messages.add({'role': 'user', 'content': jsonEncode({'language': 'Arabic', 'allow_device_command': false, 'user_text': 'طيب رحب بيا بالمصري وباسمي.'})});
      }
    }
    print('PASS: native CPU inference, JSON output, two conversation turns.');
  } finally {
    await engine.close();
  }
}
