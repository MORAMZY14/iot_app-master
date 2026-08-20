# Fully offline conversational assistant

Version 2.7 implements the conversational model inside the Android/iOS Flutter
app. It uses an imported, quantized Gemma 3 `.task` model through MediaPipe and
`flutter_gemma`. It has no OpenAI client, hosted inference endpoint, model URL,
API token, or remote fallback.

## Runtime boundary

1. The phone's installed on-device recognizer converts English/Arabic speech to
   text.
2. Existing deterministic music commands run against files imported into the
   app.
3. Flutter sends possible home commands to the ESP32 over local HTTP/BLE.
4. If natural wording needs normalization, the phone model may propose one
   canonical command.
5. Flutter accepts only a short on/off command and sends it back through the
   ESP32's existing room/device parser. Only an ESP32-confirmed match changes a
   relay.
6. Normal conversation is generated locally by the phone model. The installed
   phone TTS voice speaks the final response.

The model cannot directly access GPIO, BLE, HTTP, Firebase, or the device map.
This protects the home from hallucinated targets or generated tool calls.

## Model lifecycle

- Fine-tune `google/gemma-3-1b-it` on a laptop using the included
  [`training/`](training/README.md) kit.
- Merge the LoRA adapter, convert/quantize it with LiteRT Torch, and bundle the
  model plus tokenizer into one MediaPipe `.task` file.
- Copy that file to the phone and use **Assistant → brain/Model → Import**.
- The iOS picker is intentionally unfiltered so an unknown `.task` extension is
  selectable; Flutter validates the extension before any model installation.
- Flutter copies it into application-private support storage. It is loaded only
  on Android/iOS and remains available after a restart.
- Reset conversation clears context. Remove deletes the app's private model
  copy without touching the original laptop file.

No model weights are bundled in this source archive. A Gemma 3 1B mobile model
is hundreds of MB, and redistribution must comply with the Gemma license.

## What “trained” means

Gemma is already pretrained on language and instruction-following. The included
QLoRA pipeline fine-tunes it for customer vocabulary, English/Arabic style,
command normalization, and the strict JSON envelope used by the app. A small
smart-home dataset does not train a general LLM from zero. Reliable customer
behavior requires many reviewed examples and held-out tests.

## Hardware limits

The phone runs the LLM. A normal ESP32 does not have enough RAM or storage for
a useful conversational model. The ESP32 remains a fast deterministic control
and sensor board. An ESP32-S3 with suitable microphone/PSRAM can optionally run
fixed command recognition, but not this open-ended bilingual model.

Mobile requirements for this build are Android API 24+ or iOS 16+. The `.task`
runtime uses the CPU for compatibility with the official fine-tuned-model
conversion path. Initial loading and replies take longer than deterministic
commands, especially on older phones.

Chrome is only an interface preview for this mobile-model configuration. The
browser runtime cannot reopen an arbitrary local file path and requires WebGPU
plus a web-compatible model source, so its model button shows an explanation
instead of starting an import that cannot complete.
