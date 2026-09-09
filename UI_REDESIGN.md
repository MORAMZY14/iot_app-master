# Smart Home 2.10 — reference UI implementation

This release applies the ten supplied designs to the Flutter app. It includes the complete 2.9 offline AI/training files and ESP32 firmware, plus the new native UI and bundled photos. It is source code; no signed release or physical-device deployment is included.

## What changed

| Screen | Implemented design and behavior |
| --- | --- |
| Splash | Navy background, glowing house mark, twilight photo, actual initialization progress |
| Sign in / sign up | Photo header, glass form, segmented modes, gradient submit button; existing validation, account verification and password reset |
| Home | Compact photo header, four configurable scenes, live ESP/BLE status, sensor cards, editable room photos, room-specific controls, voice button above four-tab navigation |
| Assistant | Compact Bluetooth/AI cards, conversation panel, language selection, larger microphone, text composer; model import, memory, music and voice test retained |
| Energy | Photo header, current kWh only when supplied; honest empty state for unavailable meter/history data |
| Notifications | Photo header, unread/earlier groups, colored cards, unread badge, mark all read and clear actions |
| Settings | Appearance choices; grouped voice, Bluetooth, ESP32, account and system settings; accessible even when the controller code cannot be fetched |
| Provision ESP32 | Setup-hotspot copy buttons, optional Bluetooth, real scan results, network selection, inline credentials form |
| Wi-Fi manager | Current connection, refresh/scan, selected network, inline credentials form; existing confirmed forget-network operation |
| I/O modules | Controller header, bus cards, module cards, bus selection and enabled switches, address/wiring editor, add/delete/save actions |

`lib/ui/smart_home_design.dart` contains the shared theme, cards, headers, navigation, microphone and button components. Screens continue to use existing HTTP/BLE/controller services.

## Run on your laptop and phone

From the extracted `iot_app-master-master` folder, use Flutter 3.44.0 (Dart 3.12) or a compatible newer Flutter version:

```powershell
flutter pub get
flutter devices
flutter run
```

Choose your connected Android phone or emulator. Existing Firebase project configuration is retained. The user account, ESP32 and Wi-Fi still need to be configured normally. Keep your own Firebase files if you use a different project.

No AI retraining or ESP32 reflash is required solely for this visual update. Your training/export workflow remains in `LAPTOP_TRAINING.md`. Keep the `llamadart_native_runtimes: [llama_cpp]` hook setting: the app also supports existing Gemma `.task` models.

## Scenes, energy and real data

Tap Home, Away, Sleep or Movie to choose explicit device targets and their desired states. Save the scene, or choose **Save & run**. Scenes are stored locally per account. No unconfigured scene controls devices automatically. Device states remain the source of confirmation; a sent request is not a guarantee that a relay changed.

The supplied firmware has no energy-meter driver or historical energy series. The UI does not invent usage, cost, charts, or unsupported meter setup. Missing temperature, humidity, IP, signal or ping data is shown as unknown instead of a sample value.

Room photos use built-in living-room, bedroom, kitchen and bathroom images for recognized English/Arabic room names. The existing per-room photo picker overrides these defaults. Scenes and photos remain on the phone.

## Verification and previews

The widget tests render the actual Flutter screens, using device fixtures confined to `test/ui_redesign_test.dart`. These pictures are implementation previews, not photographs of a connected installation. Hardware-specific actions still require checking on your ESP32 and phone.

```powershell
flutter analyze
flutter test
```

All 34 Flutter tests passed, including the existing assistant tests, layout and interaction checks, and comparisons against 16 screen previews. The analyzer reports no errors; warnings and style notices remain. `validation/ui-analyze.txt`, `validation/ui-tests.txt`, and the final no-golden-update run in `validation/ui-tests-final.txt` contain the results. Golden previews are in `test/goldens/ui/`; `SmartHome-UI-Preview.html` pairs each of the ten supplied references with its corresponding real Flutter render.

The design adapts to screen size and text scaling, so smaller displays scroll instead of shrinking controls to match the phone illustrations. The microphone waveform is decorative, with an active color while listening; it is not an audio-level meter.

## Image assets

The built-in image generation tool created these new photographic assets. They are bundled locally, with no image download at runtime:

- `assets/images/smart_home_twilight.png`: architectural photograph of a modern glass house at blue hour, warm amber interiors, blue reflecting pool, navy mountain sky, centered house; no words, UI, people or logos.
- `assets/images/room_living.png`: warm modern living room, cream sofa, floor lamp, houseplants, coffee table and amber lighting, straight-on architectural photograph.
- `assets/images/room_bedroom.png`: modern upholstered bed, blue headboard accent lighting, warm bedside lamps, navy bedding and houseplants, straight-on architectural photograph.
- `assets/images/room_kitchen.png`: navy kitchen island, pale stone counter, oak cabinetry and warm pendant/under-cabinet lights, front architectural photograph.
- `assets/images/room_bathroom.png`: white freestanding bathtub, blue-gray stone, glass shower, brass fixtures and green plant in cool evening light.

All prompts specified landscape 1536×1024, realistic and uncluttered interiors, with no text, logos, UI, frames or people. These are decorative app assets, not measurements or depictions of the user's real home.
