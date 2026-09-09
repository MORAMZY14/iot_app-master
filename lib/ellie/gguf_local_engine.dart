import 'package:llamadart/llamadart.dart';

/// Files only. No model URLs, remote inference, or ESP32 requests.
class GgufLocalEngine {
  static const contextTokens = 2048;
  static const responseTokens = 384;
  final LlamaEngine _engine = LlamaEngine(LlamaBackend());
  Future<void> load(String path) => _engine.loadModel(
    path,
    modelParams: const ModelParams(
      contextSize: contextTokens,
      gpuLayers: 0,
      preferredBackend: GpuBackend.cpu,
      numberOfThreads: 4,
      numberOfThreadsBatch: 4,
      batchSize: 128,
      microBatchSize: 64,
    ),
  );
  Future<String> generate(
    List<Map<String, String>> source, {
    required bool allowDeviceCommand,
  }) async {
    final messages = source
        .map(
          (m) => LlamaChatMessage.fromText(
            role: switch (m['role']) {
              'system' => LlamaChatRole.system,
              'assistant' => LlamaChatRole.assistant,
              _ => LlamaChatRole.user,
            },
            text: m['content']!,
          ),
        )
        .toList();
    final format = <String, dynamic>{
      'type': 'json_schema',
      'json_schema': {
        'name': 'assistant_reply',
        'strict': true,
        'schema': {
          'type': 'object',
          'properties': {
            'reply': {'type': 'string', 'minLength': 1, 'maxLength': 1200},
            'device_command': allowDeviceCommand
                ? {
                    'anyOf': [
                      {'type': 'null'},
                      {'type': 'string', 'maxLength': 220},
                    ],
                  }
                : {'type': 'null'},
          },
          'required': ['reply', 'device_command'],
          'additionalProperties': false,
        },
      },
    };
    while (true) {
      final prompt = await _engine.chatTemplate(
        messages,
        enableThinking: false,
        responseFormat: format,
      );
      if ((prompt.tokenCount ?? contextTokens) <=
          contextTokens - responseTokens - 32)
        break;
      if (messages.length <= 2)
        throw const FormatException(
          'Please shorten your message or saved preferences.',
        );
      messages.removeRange(1, 3);
    }
    final output = StringBuffer();
    await for (final chunk in _engine.create(
      messages,
      enableThinking: false,
      responseFormat: format,
      params: GenerationParams(
        maxTokens: responseTokens,
        temp: allowDeviceCommand ? 0.2 : 0.7,
        topP: 0.8,
        topK: 20,
        penalty: 1.05,
      ),
    )) {
      for (final choice in chunk.choices) {
        final text = choice.delta.content;
        if (text != null) output.write(text);
      }
    }
    return output.toString();
  }

  Future<void> close() => _engine.dispose();
}
