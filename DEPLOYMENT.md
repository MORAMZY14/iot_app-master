# SmartHome local/offline build guide

This is a development/source package with a local voice assistant. It does not
include an OpenAI connection, assistant backend, API key, cloud speech service,
private Android upload key, or Apple signing identity.

Android requires installable APKs to have a signature, so test APKs use only
Flutter's standard debug key. iOS uses `--no-codesign` and produces an unsigned
IPA for an external re-signing workflow.

## 1. Prepare and verify Flutter

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Install offline English and Arabic speech-recognition/TTS voices in the phone's
system settings. The app deliberately does not fall back to network recognition.

## 2. Run locally

```bash
flutter run
```

No backend URL or assistant API key is required. The phone and ESP32 must be
reachable over the existing local Wi-Fi or BLE control path. If the controller
does not use the default `192.168.1.9`, set only its LAN address:

```bash
flutter run --dart-define="ESP32_LOCAL_IP=192.168.1.50"
```

## 3. Flash the integrated ESP32 firmware

The complete supplied sketch is included here:

```text
esp32_firmware/SmartHomeOffline/SmartHomeOffline.ino
```

In Arduino IDE, install the ESP32 board package plus ArduinoJson 6.x,
NimBLE-Arduino, DHT sensor library, and Adafruit Unified Sensor. Install
ESP8266Audio and ESP8266SAM only if local English speech through an I2S speaker
is required. Then select the exact ESP32 board and port, click **Verify**, click
**Upload**, and open Serial Monitor at 115200 baud.

The sketch keeps the supplied GPIO, PCF8574, BLE, HTTP, sensor, device, and
optional Firebase synchronization code. Assistant processing is fully local:

- `POST /api/ellie` — match local text and perform safe home actions,
- `POST /api/ellie/speak` — queue locally generated English speech,
- `GET/POST /api/assistant/name` — read or persist the customer name in ESP32
  Preferences/NVS, and
- the existing BLE service/command characteristic — local fallback when LAN
  control is unavailable.

There is no remote-audio endpoint, speech ticket, AI API key, or unknown-command
assistant network fallback. See
`esp32_firmware/SmartHomeOffline/README.md` for the retained pin map, first Wi-Fi
setup, local endpoint examples, and the no-microphone hardware limitation.

## 4. Android test APK — no production key

Normal debug APK:

```bash
flutter build apk --debug \
  --dart-define="ESP32_LOCAL_IP=192.168.1.50"
```

Output: `build/app/outputs/flutter-apk/app-debug.apk`

Release-mode performance using only the test/debug key:

```bash
flutter build apk --release \
  --dart-define="ESP32_LOCAL_IP=192.168.1.50"
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

No `key.properties`, private keystore, upload key, or Google Play signing setup
is included.

## 5. Unsigned iOS IPA

Use a Mac with Flutter, Xcode, and CocoaPods:

```bash
flutter clean
flutter pub get
cd ios && pod install --repo-update && cd ..

flutter build ios --release --no-codesign \
  --dart-define="ESP32_LOCAL_IP=192.168.1.50"

cd build/ios/iphoneos
mkdir -p Payload
cp -R Runner.app Payload/
zip -r iot-unsigned.ipa Payload
```

The resulting IPA is unsigned and not directly installable. The included GitHub
Actions workflow automates the same no-codesign packaging flow.

## 6. Optional web preview

```bash
flutter build web --release
firebase login
firebase deploy --only hosting --project "iot-smart-home-81abd"
```

Typed local assistant commands can be tested in a compatible browser. Offline
browser speech recognition varies by browser, and an HTTPS page normally cannot
call an ESP32's plain HTTP address because of mixed-content and CORS rules.

## 7. Direct ESP32 microphone option

If the board is an ESP32-S3 with an I2S microphone and sufficient flash/PSRAM,
Espressif ESP-SR MultiNet can recognize a fixed English command list locally.
It is not open-ended speech-to-text and does not provide the bilingual
generative conversation that a cloud model would provide. The phone-to-ESP text
path remains the reliable bilingual offline configuration for this project.
