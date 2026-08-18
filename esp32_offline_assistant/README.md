# Reusable ESP32 offline assistant module

This directory is an optional reusable intent/router for another firmware
project. The user's complete supplied firmware has already been integrated in
`../esp32_firmware/SmartHomeOffline/`; that sketch does not need this module.

`OfflineVoiceAssistant` has no Wi-Fi cloud dependency, API key, OpenAI client,
or remote model. Flutter performs on-device speech recognition, sends only text
to the ESP32 over local HTTP or BLE, and receives a small JSON result. The ESP32
module delegates real device matching to your existing firmware callback.

## Add it to the current firmware

1. Copy `OfflineVoiceAssistant.h` and `OfflineVoiceAssistant.cpp` beside the
   existing Arduino/PlatformIO firmware source.
2. Include the header and connect the callbacks:

```cpp
#include "OfflineVoiceAssistant.h"

bool handleHomeIntent(const String& text, bool arabic, String& reply) {
  // Call the existing room/device/sensor parser here.
  // Return true only after a recognized local command is handled safely.
  return false;
}

bool queueLocalSpeech(const String& text, bool arabic) {
  if (arabic) {
    // Map known replies to Arabic audio clips stored in flash, if available.
    return false;
  }
  // Queue the existing ESP8266SAM/MAX98357A English speech path here.
  return true;
}

OfflineVoiceAssistant assistant(
    "Ellie",
    handleHomeIntent,
    queueLocalSpeech);
```

3. In the existing `POST /api/ellie` and BLE text-command handlers, pass the
   received `text`, `language`, and `speak` values to `assistant.handle(...)`.
4. Return these fields as JSON so the included Flutter controller can read it:

```json
{
  "handled": true,
  "needsFallback": false,
  "speakerQueued": true,
  "reply": "The living room light is on.",
  "offlineReply": ""
}
```

## Direct microphone on the ESP32

The supplied module processes text; it does not pretend that a basic ESP32 can
run a general multilingual LLM or full speech-to-text model. If the hardware is
an **ESP32-S3** with an I2S microphone and suitable PSRAM/flash, Espressif's
[ESP-SR MultiNet](https://docs.espressif.com/projects/esp-sr/en/latest/esp32s3/speech_command_recognition/README.html)
can recognize a fixed set of English commands offline. It is command
recognition—not open-ended transcription—and the official model does not list
Arabic command support.

For this bilingual project, the practical offline path is:

1. phone microphone → installed on-device English/Arabic recognizer,
2. recognized text → ESP32 over local Wi-Fi or BLE,
3. ESP32 → deterministic device/sensor action,
4. response → installed phone TTS voice, with optional locally stored ESP32
   audio clips.

For this application's concrete routes, BLE characteristics, device table,
speaker queue, and flashing instructions, use
`../esp32_firmware/SmartHomeOffline/README.md`.
