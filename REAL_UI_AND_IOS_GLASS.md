# Smart Home 2.11: real controls and iOS glass

The app no longer uses cropped screenshots as microphone, branding, avatar, room artwork or module icons. Icons, text, buttons, switches and navigation are real widgets. Only standalone house and room photographs remain; room photos can be changed.

The room action buttons have larger labels and touch targets. The microphone changes between mic and stop states. Scrolling content can pass behind the floating navigation, with bottom padding allowing the final controls to scroll fully above it.

## iOS 26

Build on a Mac using Xcode 26 or newer with the iOS 26 SDK, then run on iOS 26 or newer. The bridge in `ios/Runner/AppDelegate.swift` embeds a real UIKit `UITabBar`, allowing the system to supply Liquid Glass. It sends tab taps to Flutter and receives selected tab, theme, direction and unread badge updates. Android, older iOS and unavailable native bridges use an interactive Flutter bar with blur and animated selection.

The existing app uses the AppDelegate lifecycle. If migrating to UIScene, move this registration together with the other plugin registrations to the implicit-engine callback.

Native iOS rendering and Swift compilation cannot be verified in this Linux workspace. Check on an iPhone or simulator: all tabs, badges, light/dark modes, VoiceOver, Reduce Transparency, rotation, assistant sheet presentation and bottom safe area. This is source code, not a signed or device-verified iOS build.

- [Apple: adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Flutter: hosting native iOS views](https://docs.flutter.dev/platform-integration/ios/platform-views)

## Run

```powershell
flutter pub get
flutter test test/real_controls_test.dart
flutter run
```

The firmware, training scripts and datasets are preserved. Follow `LAPTOP_TRAINING.md` for the existing AI workflow. Previous 2.10 validation logs are historical; current verification is recorded separately in `validation/real-ui-validation.md`. The screenshots in `test/goldens/ui` have been regenerated from the 2.11 Flutter widgets; they show the cross-platform fallback, not the native iOS glass rendering.
