# Build configuration patch — 2 October 2026

Version: **2.12.1+48**. This patch responds to the supplied Flutter 3.47.6 CI logs.

## Corrections

- `dashboard_page.dart` imports `login_screen.dart`; `LoginScreen` already has
  a const constructor. The missing import caused the reported Dart failure.
- Android compiles and targets API 36, with minimum API 24 unchanged. Gradle
  9.1.0, AGP 9.0.1, Kotlin 2.3.20 and Google Services 4.5.0 replace the previous
  tool versions. The legacy Kotlin/AGP DSL compatibility opt-outs remain enabled
  for the retained native plugins, following Flutter's migration guidance.
- Flutter 3.47.6 is pinned in source and all CI jobs. API 36 and build tools
  36.0.0 are explicitly installed in the Android CI jobs.
- Runner's Debug, Release and Profile configurations include the matching
  CocoaPods settings. Release/Profile include the unsigned settings; all Pods
  targets also disable signing and clear their team/identity/profile fields.
- Both the pubspec and preparation/build scripts disable SwiftPM for the
  retained CocoaPods-only plugins. No plugin-support warning is filtered out.
- The iOS script keeps a verbose log, preserves compiler failure status,
  verifies the app has no signature/provisioning profile, then creates a `.app`
  ZIP. The old manual workflow is replaced at its original filename; its build
  no longer needs an Apple account or automatically bumps/publishes versions.

## Checks performed here

| Check | Result |
| --- | --- |
| `python3 tool/verify_build_policy.py` | Passed |
| Official Gradle 9.1.0 wrapper JAR | SHA-256 `76805e32c009c0cf0dd5d206bddc9fb22ea42e84db904b764f3047de095493f3`, matching Gradle's published checksum |
| Official Gradle 9.1.0 binary distribution checksum | `a17ddd85a26b6a7f5ddb71ff8b05fc5104c0202c6e64782429790c933686c806` pinned in wrapper properties |
| OpenStep Xcode project parser | Passed; all Runner xcconfig file references resolve |
| iOS plist parsing and three workflow YAML files | Passed |
| Bash syntax: preparation, unsigned iOS and offline integration scripts | Passed |
| Dart grammar parsing | 59 source/test/tool files; no grammar errors. This is not Dart type analysis. |
| Offline app/firmware contract | Passed; matching BLE UUIDs and 34 valid training conversations |
| Mocked iOS script: compiler failure | Preserved exit 42 through `tee`; no artifact |
| Mocked iOS script: signed app, unrelated signing-tool failure, provisioning profile | All rejected with exit 1; no artifact |
| Mocked iOS script: confirmed unsigned app | Created the artifact only after both unsigned checks |

Flutter, Dart and Xcode are unavailable in this workspace. Real Flutter analysis,
dependency resolution, Gradle/Kotlin/R8 compilation, CocoaPods installation,
Swift compilation and native signing checks remain unverified. The generic iOS
team diagnostic alone did not include the underlying Xcode error; the next CI
run retains its verbose build log instead of hiding or reclassifying failures.
No successful APK/AAB/iOS build is claimed by these source and script checks.

## Primary build references

- [Flutter's AGP 9 / Kotlin migration guidance](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin)
- [Android Gradle Plugin 9.0.1 compatibility requirements](https://developer.android.com/build/releases/agp-9-0-0-release-notes)
- [Kotlin Gradle version compatibility](https://kotlinlang.org/docs/gradle-configure-project.html)
- [Firebase Android plugin setup](https://firebase.google.com/docs/android/setup)
- [Flutter SwiftPM opt-out settings](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)
- [Gradle release checksums](https://gradle.org/release-checksums/)
