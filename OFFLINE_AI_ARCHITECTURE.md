# Fully offline conversational assistant

The current Flutter assistant handles on-device speech recognition, phone TTS,
and local ESP32 commands. Its open-ended fallback is rule-based, not a trained
AI model.

For a genuine conversational assistant without OpenAI or cloud inference, use
this split:

1. Flutter phone: runs a quantized multilingual language model and keeps the
   chat context.
2. ESP32: exposes a strict local command API and controls the relays/sensors.
3. Flutter validates a model-proposed home action against the actual room and
   device list before sending it to the ESP32.
4. Phone TTS speaks the final answer. The ESP32 speaker remains an optional
   English command-confirmation output.

Recommended prototype model: Qwen3 0.6B through LiteRT-LM / flutter_gemma. It
is multilingual, supports function calling, and is about 586 MB. The model can
be downloaded once into app-private storage and then used with airplane mode.
Bundling it in the application is also possible, but makes the install package
very large.

Do not attempt to run the conversational model on an ESP32. Even the smallest
useful trained chat models need hundreds of megabytes of storage and far more
RAM than an ESP32 provides. Keep the ESP32 deterministic so a generated answer
cannot directly perform an unsafe or nonexistent device action.

Before integrating the model runtime, choose the target hardware and delivery
method:

- one-time in-app download (smaller app package; recommended), or
- model bundled with the app (very large package; fully offline from first
  launch).

The project deliberately does not pretend the rule-based fallback is a trained
AI. Keep this boundary visible until the model runtime and model file have both
been installed and tested on the target iPhone/Android device.
