# SmartHome 2.6 — local music, multi-device commands, and audible replies

## Prototype 2.6 assistant update

- A private on-phone music library now imports MP3, M4A, AAC, WAV, and other
  audio files selected through the system file picker. Files are copied into
  the app sandbox and never uploaded.
- Voice or typed commands support **play music**, **play _song name_**,
  **pause**, **resume**, **stop**, **next**, **previous**, and **what song is
  playing** in English and Arabic.
- The ESP32 can safely match several differently named targets in one command,
  such as **“turn off TV and Desk Lamp.”** A request for “two devices” without
  names asks for both names instead of selecting relays arbitrarily.
- iPhone replies now use the phone speaker by default. Speech-to-text and TTS
  initialize independently, the recording session is fully released before
  playback, incompatible playback/Bluetooth audio options were removed, and a
  native on-device `AVSpeechSynthesizer` fallback is included.
- The old generic “one voice output unavailable” warning is replaced with a
  specific phone or optional-ESP32 speaker diagnostic.
- Firmware reports `2.6.0-music-multidevice`; Flutter is `2.6.0+41`.

Local music means audio files imported into this app. Selecting songs from a
Spotify or Apple Music subscription would require those services and is not a
fully offline feature.

## Prototype 2.5 controller reliability update

- BLE write callbacks now only enqueue command bytes. Parsing, device-map
  access, I²C relay changes, and BLE replies run safely from Arduino `loop()`.
- Command-triggered Firebase HTTPS updates run on a low-priority worker instead
  of blocking the local HTTP server and BLE control loop.
- Each BLE reply has a monotonically increasing response sequence, preventing
  Flutter from mistaking an old characteristic value for a new command result.
- Flutter completes its initial BLE status/device refresh before allowing the
  first assistant command and briefly serializes overlapping BLE operations.
- Every I²C controller has a 30 ms transaction timeout so a disconnected or
  stuck PCF8574 bus cannot hold the controller indefinitely.
- Firmware reports `2.5.0-freeze-safe-assistant` and the Flutter build is
  `2.5.0+40`.

## Prototype 2.4 interface and voice fixes

- The duplicate voice-assistant action was removed from the phone header. The
  centered bottom button is now the single mobile entry point.
- The selected-room hero stretches across the complete panel and keeps
  `BoxFit.cover`, including customer-selected gallery or camera photos.
- Clear power phrases now support any customer device name, such as
  **“Turn on Laptop”**, instead of only a fixed list of device types.
- If local Wi-Fi is unavailable (for example while the phone is on 4G), an
  assistant command automatically attempts the existing ESP32 BLE connection.
- The assistant sheet shows the real BLE state and includes a manual local
  connect/retry button instead of displaying a generic local-mode disclaimer.
- iOS speech output restores its playback audio session after microphone use
  and has a bounded completion timeout, preventing a permanent “speaking” state.

## Prototype 2.3 integration update

- The complete assistant intent engine is inside the supplied ESP32 firmware,
  not in a separate demonstration sketch.
- Flutter and the assistant now use the same dynamically discovered controller
  IP. A compile-time `ESP32_LOCAL_IP` remains an optional override.
- BLE status returns the controller IP, firmware version, assistant name,
  assistant readiness, speaker capability, temperature, humidity, and flame
  state.
- Assistant-name changes, commands, device state, sensors, and speech output
  share the same HTTP/BLE contract.
- Firmware reports version `2.5.0-freeze-safe-assistant`, allowing the app and
  serial/BLE diagnostics to identify the integrated build.

## Prototype 2.2 room and voice update

- The mobile center button opens the voice assistant.
- Add/manage room and add-device controls sit beside **Your Rooms**.
- Every room card has a photo button. Photos can come from the gallery or
  camera, are resized, and stay locally on that phone.
- The selected room's large control panel uses the same custom photo.
- iOS phone speech uses a playback audio session, so assistant speech is
  audible when the hardware silent switch is enabled. Use the speaker icon in
  the assistant header to test it.

The current open-ended fallback is intentionally deterministic; it is not a
trained language model. A genuine no-cloud conversational assistant requires
an on-device model running on the phone. The ESP32 remains the safe home-command
executor because it cannot run a useful conversational LLM. See
`OFFLINE_AI_ARCHITECTURE.md` for the recommended design.

This Flutter project uses the room-first dashboard and a bilingual English and
Arabic voice assistant. The assistant now runs without OpenAI, a remote AI API,
or a cloud conversation backend.

The smart-home application still keeps its existing Firebase sign-in/device
sync behavior. Firebase is not used to generate assistant replies, process
speech, or store the assistant name.

## Local assistant architecture

1. Flutter requests the phone's installed on-device speech recognizer.
2. Recognized text is sent to the ESP32 over local Wi-Fi, with BLE fallback.
3. The ESP32 handles deterministic room, relay, device, and sensor intents.
4. Flutter provides built-in local replies for help, identity, time, date,
   greetings, thanks, and unsupported requests.
5. Replies use an installed phone TTS voice. English can also use the existing
   ESP32 local speaker path.

There is no OpenAI package, assistant server, API key, cloud TTS ticket, or
`ELLIE_BACKEND_URL` in this version.

## Room-first interface

- Large visual cards show every real room and its device counts.
- Selecting a room shows only that room's device controls.
- Room-wide **All on** and **All off** actions are included.
- Desktop uses side navigation; phones use bottom navigation.
- The interior artwork is original and bundled locally.

## Customer assistant names

Open **Settings → Voice Assistant → Rename**. The 2–24 character name is stored
locally on the phone, then synchronized to the ESP32 over local Wi-Fi or BLE.
The ESP32 keeps it in local Preferences/NVS across restarts. It is used by the
dashboard, wake phrase, bilingual prompts, firmware replies, and local commands.

The default is **Ellie / إيلي**. No customer assistant name is stored in
Firebase or sent to a remote assistant.

## Offline behavior and limits

- Voice recognition is forced to on-device mode; there is no network fallback.
- Install English and Arabic speech-recognition and TTS language packs in the
  phone settings before testing.
- Typed commands remain available when an offline speech pack is unavailable.
- The local assistant is deterministic, not a general generative chatbot.
- Arabic replies are spoken by the installed phone voice. ESP32 Arabic output
  requires known audio clips stored locally in its flash.
- A basic ESP32 receives recognized text from Flutter. Direct microphone-based
  command recognition requires suitable ESP32-S3 audio hardware and ESP-SR.

## ESP32 integration

The supplied firmware is now integrated at
[`esp32_firmware/SmartHomeOffline/SmartHomeOffline.ino`](esp32_firmware/SmartHomeOffline/SmartHomeOffline.ino).
It keeps the original GPIO, PCF8574, BLE, HTTP, device, sensor, and optional
Firebase synchronization behavior while removing the assistant's cloud
conversation and remote-audio paths. Exact libraries, pins, flashing steps, and
local API commands are in the
[`firmware README`](esp32_firmware/SmartHomeOffline/README.md).

[`esp32_offline_assistant/`](esp32_offline_assistant/README.md) remains only as
a small reusable module for another firmware project; the complete bundled
sketch does not require that extra module.

## Run and build

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

If the controller does not use the default `192.168.1.9`, pass only its local
LAN address; this is not a server or cloud URL:

```bash
flutter run --dart-define="ESP32_LOCAL_IP=192.168.1.50"
```

The project intentionally contains no private mobile signing credentials. See
[`DEPLOYMENT.md`](DEPLOYMENT.md) for test APK, unsigned iOS IPA, web preview,
and ESP32 integration steps.
