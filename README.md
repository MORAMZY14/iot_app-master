# SmartHome 2.12.1

Updated Flutter mobile source with Material 3 screens, real room/device controls,
light/dark/system themes, Firebase accounts, ESP32 HTTP/BLE control, and private
English/Arabic voice assistance. Both imported Gemma `.task` and Qwen `.gguf`
models, local music, ESP32 firmware, and laptop training tools are included.
No room photographs or model weights are bundled in the Flutter app.

This package contains production hardening changes. Signed Android/iOS builds,
Flutter analysis/tests, physical-device verification, and firmware/backend
security completion are still required before public distribution.

## Start here

- **[Production review and verification](docs/PRODUCTION_REVIEW.md)** — changes,
  exact source/asset savings, remaining release blockers, and available checks.
- **[Mobile build and signing](docs/RELEASE.md)** — pinned toolchain, dependency
  refresh, signed Android artifacts, iOS distribution, and device checks.
- **[LAPTOP_TRAINING.md](LAPTOP_TRAINING.md)** — Qwen3-1.7B workflow for the
  GTX 1650 4 GB laptop: training, resume, evaluation, GGUF export and phone import.
- **[ESP32 setup](esp32_firmware/SmartHomeOffline/README.md)** — current firmware
  and hardware connections. Read the security limitations in the production
  review before deploying this firmware outside a trusted development network.
- **[Dataset](training/dataset/DATASET_CARD.md)** and
  **[Gemma conversion](GEMMA_LEGACY_GUIDE.md)** — retained training resources.

## Prepare the mobile build

Install Flutter **3.47.6**, JDK 17 and Android SDK 36. From this directory:

```sh
bash tool/prepare_dependencies.sh --refresh
dart format lib test tool
flutter analyze --no-fatal-infos
flutter test --coverage
bash tool/validate_offline_integration.sh
```

The original lockfile is retained as the resolved baseline; the command performs
real resolution, prunes removed dependencies and regenerates native registrants.
Review and retain the resulting `pubspec.lock` and iOS `Podfile.lock`.

Configure your private upload key using `android/key.properties.example`, then:

```sh
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols
```

Keep the symbols and Android mapping with the matching release. Production
Android builds reject missing signing credentials and debug certificates.
For an unsigned iOS release on a Mac, run `bash tool/build_ios_unsigned.sh`.
This creates a `.app` ZIP without an Apple team, certificate or profile.
The verification, signed Android release and unsigned iOS release workflows
are in `.github/workflows/`; they do not automatically publish stores or push
tags. Replace the included workflow files along with the app/native source.

The LLM runs on the phone; training runs on the laptop. The ESP32 executes
hardware commands rather than the language model. No cloud inference fallback
or remote model download was introduced. Historical validation files describe
older versions and are not evidence that this update has been mobile-built.
