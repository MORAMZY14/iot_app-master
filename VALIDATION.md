# Validation for SmartHome 2.8

Checked in this workspace with Flutter 3.44.0 / Dart 3.12, Python 3.12, and the ESP32 Xtensa compiler 8.4.0.

| Check | Result |
| --- | --- |
| Flutter dependency resolution | Completed; updated pubspec.lock included |
| Flutter test suite | 14 tests passed |
| New room-card visual tests | Passed at 320 px in light/dark themes and with 2x text; golden PNGs inspected |
| Training utility unit tests | 8 passed |
| Dataset validation | 34 training examples and 24 disjoint held-out examples passed |
| C++ control intent tests | 16 host assertions passed |
| ESP32 CloudTransport header | Compiles in syntax-only mode against real ESP32 Arduino 2.0.17 headers |
| Complete SmartHomeOffline sketch | Syntax-only compilation passed with real ArduinoJson 6.21.5, NimBLE 2.3.6, DHT 1.4.6, Adafruit Sensor 1.1.15 and ESP32 headers; speaker disabled |
| Offline integration contract script | Passed |
| Python scripts | Syntax compilation and command-line help checked |

Static analysis found no errors. Existing unused-code/style/deprecation warnings remain in legacy login, setup and dashboard code; analyzer output is included in `validation/dart-analyzer.txt`.

## Limits

- No trained weights were supplied. GPU fine-tuning, actual model evaluation, merging and TFLite/task generation were not executed. The GTX 1650 profile needs the documented two-step memory test on the user's laptop.
- The full PlatformIO build stopped because its esptool package could not be downloaded successfully. Failed integrity checks were not bypassed. The standalone syntax check uses successfully obtained official framework/toolchain/library sources; it does not link an image, check final flash usage, or verify firmware behavior.
- No Android APK, signed iOS package, physical phone microphone/TTS/model run, or ESP32 flash/upload was performed.
- The Android native offline-recognizer capability method still needs an Android build/device test. Android voice is restricted to an available on-device recognizer; typed commands remain supported.
- Room-card images are component visual checks, not a full authenticated dashboard screenshot or an end-to-end phone test.
- Live relays, cloud retry memory, BLE timing, actual I/O failures and bilingual device matching require the checklist in GEMMA_LEGACY_GUIDE.md. No measured speedup or guaranteed model quality is claimed.

The first Flutter setup attempt was rejected by automatic approval review when Flutter's environment detector tried a cloud metadata endpoint. Reading Flutter's source established that CI mode skips that request; subsequent checks used CI mode and succeeded.
