# Reference-inspired home update

- Populated the home header with My Home, room count, active device count, and a morning/afternoon/evening greeting over the existing house photograph.
- Room photos fill the cards, with gradient overlays, readable room labels, and temperature/humidity inside each card and the selected room controls.
- Readings use the existing shared ESP32 home sensor feed, explicitly labeled Home sensor. Missing or non-finite readings display an em dash; zero remains valid. Separate room measurements require separate sensor data/mapping.
- Refined the bottom Voice control into a full-width tappable dock with a gradient microphone, assistant name, and suggested command. It opens the existing assistant sheet. The large assistant microphone is preserved.
- Native iOS 26 UITabBar, platform bridge, capability detection, and fallback navigation are unchanged.

## Validation

Dart syntax parsing passed for the changed source files. Original archive comparison confirms the native navigation files are unchanged. Updated the existing voice interaction test and added missing/zero climate coverage.

This environment has no Flutter SDK, Xcode, or iOS simulator. Flutter analysis, widget tests, new screenshots, and an iOS build have NOT been run. Existing golden PNGs represent the previous UI; review regenerated images before accepting them.

On a Flutter-equipped machine:

```sh
flutter pub get
flutter analyze
flutter test test/real_controls_test.dart
flutter test test/room_photo_card_test.dart --plain-name 'climate distinguishes missing readings from zero'
flutter test test/room_photo_card_test.dart test/ui_redesign_test.dart --update-goldens
```

Review the regenerated goldens, then run the widget tests normally. Confirm scrolling clears the Voice dock/tab bar on small phones, large text remains usable, and native tabs work on iOS 26.
