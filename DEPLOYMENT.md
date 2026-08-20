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
Because 2.7 adds a native MediaPipe/LiteRT model runtime, use Flutter with Dart
3.6 or newer and run `flutter clean` once before the first 2.7 build, then run
`flutter pub get` again. Mobile targets are Android API 24+ and iOS 16+.

This project temporarily disables Flutter's Swift Package Manager integration
because several required plugins, including `flutter_gemma`, still use
CocoaPods. The iOS Podfile, Xcode project, Flutter framework plist, and all pods
are pinned to iOS 16.0. Do not accept an automated migration back to iOS 15.

To create a trained model, follow [`training/README.md`](training/README.md).
Copy the resulting `.task` file to the phone, open the center assistant button,
then use **brain/Model → Import `.task` model**. No model is downloaded by the
app and no Hugging Face/OpenAI credential is compiled into it.

On iPhone, the picker deliberately shows all document types because iOS can
grey out files with the unregistered `.task` extension when a custom filter is
used. Select `smart.task`; the app validates the extension itself and streams
the approximately 1 GB copy rather than loading it all into memory. Keep the
app open while the progress indicator is visible and allow several GB of free
storage for the original file, the app-private copy, and runtime working space.

In the assistant, tap the music-library icon, choose **Add songs**, and select
local audio files from Files. The app copies them into its private sandbox so
commands such as `play Blinding Lights`, `pause music`, and `next song` keep
working without a server. Spotify/Apple Music catalogue search is intentionally
not used because this build is fully local.

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

This is the single combined firmware. It already contains the offline
assistant parser, HTTP endpoints, BLE commands, name persistence, PCF8574
control, sensor reads, and optional I2S speech queue.

In Arduino IDE, install the ESP32 board package plus ArduinoJson 6.x,
NimBLE-Arduino, DHT sensor library, and Adafruit Unified Sensor. Install
ESP8266Audio and ESP8266SAM only if local English speech through an I2S speaker
 is required. Then select the exact ESP32 board and port, click **Verify**, click
**Upload**, and open Serial Monitor at 115200 baud.

For this build, confirm that BLE status or Serial diagnostics report
`2.6.0-music-multidevice`. Flutter `2.7.0+42` deliberately keeps that local
firmware protocol while adding the phone model; the ESP32 does not need the LLM
or a model file.

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

### Command responsiveness check

After flashing, send the same device command five times over local Wi-Fi and
five times with phone Wi-Fi disabled so BLE is used. The relay and reply should
remain responsive even if Internet access is unavailable. Serial Monitor should
show `BLE command:` entries without watchdog resets. If it prints an I²C write
error, check PCF8574 power, common ground, SDA/SCL pull-ups, address jumpers, and
the configured bus pins; the 30 ms bus timeout now prevents that wiring fault
from indefinitely blocking the controller.

Then test `turn off TV and Desk Lamp` using two actual configured device names.
Only those two relays should change, and both names should appear in the reply.
The command `turn off two devices` should ask you to name them.

### iPhone reply check

Open the assistant and tap the speaker icon. You should hear the customer
assistant name through the current iPhone media route. If not, raise **media**
volume (not ringtone volume), disconnect an unwanted Bluetooth audio route, and
install the selected English/Arabic system voice. Version 2.7 uses the phone as
the default bilingual reply speaker; the ESP32 I²S speaker is optional.

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

The Android project compiles against API 35. The Gradle/AGP/Kotlin notices from
new Flutter versions are deprecation warnings, not the resource-linking error;
do not use `--android-skip-build-dependency-validation` to hide them. The old
`android:postSplashScreenTheme` entry was invalid and has been removed.

## 5. Unsigned iOS IPA

Use a Mac with Flutter, Xcode, and CocoaPods:

```bash
flutter clean
flutter config --no-enable-swift-package-manager
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

The warning `Building for device with codesigning disabled` is expected. It is
not a build failure. A physical iPhone still requires the finished IPA to be
signed later with an Apple development/ad-hoc identity before installation.

## 6. Optional web preview

```bash
flutter build web --release
firebase login
firebase deploy --only hosting --project "iot-smart-home-81abd"
```

Typed deterministic assistant commands can be tested in a compatible browser.
The imported mobile `.task` model is intentionally Android/iOS-only in this
prototype. The browser model button is clickable only to show this platform
explanation; use a physical Android/iPhone for importing `smart.task`. Offline
browser speech recognition varies by browser, and an HTTPS
page normally cannot call an ESP32's plain HTTP address because of mixed-content
and CORS rules.

## 7. Direct ESP32 microphone option

If the board is an ESP32-S3 with an I2S microphone and sufficient flash/PSRAM,
Espressif ESP-SR MultiNet can recognize a fixed English command list locally.
It is not open-ended speech-to-text and does not provide the bilingual
generative conversation that a cloud model would provide. The phone-to-ESP text
path remains the reliable bilingual offline configuration for this project.
