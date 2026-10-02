# Mobile build and release

The project pins Flutter **3.47.6** in `.flutter-version`, matching the SDK in
the reported CI failures. Use JDK 17, Android SDK 36, and a Mac with Xcode for iOS. Android remains
API 24+; iOS remains 16.4+. Do not change the AI plugins' minimum platform
versions or bundle a second LiteRT runtime to reduce size.

Android now uses Gradle **9.1.0**, AGP **9.0.1**, Kotlin **2.3.20**, and Google
Services **4.5.0**. The wrapper JAR and smaller `-bin` distribution are both
verified against Gradle's published SHA-256 values. `android.builtInKotlin=false`
and `android.newDsl=false` retain Flutter's supported AGP 9 compatibility path
for existing native plugins; remove them only after every plugin migrates.
The inference plugin versions are unchanged. CI installs API 36 and its build
tools explicitly rather than depending on the runner's preinstalled platforms.

The 2.12.1 build patch also imports `LoginScreen` in the dashboard, fixing the
reported `Not a constant expression` compiler failure. That constructor was
already const; the reference was outside the dashboard library's imports.

Replace the full source, including `.github/workflows`, `android/`, `ios/`,
`pubspec.yaml` and `.flutter-version`. Updating only `lib/` leaves the previous
native build settings and floating Flutter workflow active.

## First dependency refresh

This source update removes 22 unused direct packages and excludes the six
non-logo bundled image assets (13,870,727 uncompressed source bytes). It retains
Firebase Core/Auth/RTDB, Riverpod, BLE/Wi-Fi, local voice/music, Gemma `.task`,
and llama.cpp GGUF engines. The launcher logo remains a build input; Flutter
does not bundle it or the photo directory at runtime.

| Removed group | Packages |
| --- | --- |
| Unused Firebase services | `cloud_firestore`, `cloud_functions`, `firebase_storage`, `firebase_app_check`, `firebase_messaging` |
| Unused state wrappers | `provider`, `flutter_hooks`, `hooks_riverpod` |
| Unused image/UI/icon wrappers | `cupertino_icons`, `carousel_slider`, `font_awesome_flutter`, `flutter_svg`, `google_fonts`, `cached_network_image`, `haptic_feedback` |
| Unused network plugins | `url_launcher`, `wifi_scan` (active provisioning still uses `wifi_iot`) |
| Removed photo import | `image_picker` |
| Unused integrations | `onesignal_flutter`, `flutter_contacts`, `mailer`, `twilio_flutter` |

**The included lockfile is the original resolved baseline, pending a real
Flutter refresh.** Flutter was unavailable in the hardening workspace. No
replacement dependency graph or successful mobile build is claimed. On the
pinned SDK run:

```sh
bash tool/prepare_dependencies.sh --refresh
git diff -- pubspec.lock
dart format lib test tool
flutter analyze --no-fatal-infos
flutter test --coverage
bash tool/validate_offline_integration.sh
flutter build apk --debug
```

Review and commit the pruned `pubspec.lock`. The preparation command regenerates
native plugin registrants and CMake plugin lists; stale generated implementations
have been removed from this source package and are ignored. Never hand-maintain
these lists or copy them from an older build. Their regeneration does not remove
the handwritten Android/iOS speech bridges or native navigation view.

Verification CI runs normal package resolution with exact direct versions from
the baseline, then enforces the resulting lockfile in that same job. It attaches
the resolved lockfile for reproducibility, reports formatting, checks analyzer
warnings/tests, verifies the missing-key failure, and compiles Android debug and
unsigned iOS. This allows the first real build to prune unused dependencies
without being blocked solely by that pruning. Review and commit its resolved
lock for later runs; `--locked` is available once the checked-in graph is current.
Keep `ios/Podfile.lock` after the first real CocoaPods resolution and review its
graph before signed iOS distribution.

## Android signing

All Android release builds require a private upload key. There is no debug-key
fallback and no bypass flag. Debug builds do not require release credentials.
Create the upload keystore outside the repository, with `keytool` prompting for
the passwords rather than passing them on a command line:

```sh
keytool -genkeypair -v -keystore /private/path/upload-keystore.jks \
  -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Copy `android/key.properties.example` to ignored `android/key.properties` and
fill its four values. Keystore paths are absolute or relative to `android/`.
Environment variables override the properties file:

| Property | Environment variable |
| --- | --- |
| `storeFile` | `SMARTHOME_UPLOAD_STORE_FILE` |
| `storePassword` | `SMARTHOME_UPLOAD_STORE_PASSWORD` |
| `keyAlias` | `SMARTHOME_UPLOAD_KEY_ALIAS` |
| `keyPassword` | `SMARTHOME_UPLOAD_KEY_PASSWORD` |

Build an AAB for store delivery; Play can deliver a device-specific ABI build.
Use split APKs for direct installation. This avoids one universal APK carrying
every ABI without removing either AI runtime or changing supported targets.
R8 code shrinking, resource shrinking, Flutter icon tree shaking, and Dart
obfuscation with retained symbols are part of this path:

```sh
bash tool/prepare_dependencies.sh --refresh
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols
python3 tool/verify_build_policy.py --resolved \
  --artifact build/app/outputs/bundle/release/app-release.aab
```

Archive `build/symbols/`, `build/app/outputs/mapping/release/mapping.txt`, the
exact source tag, and the resolved dependency reports together in private
release records. Keep them beyond CI's artifact retention period. Dart's
`flutter symbolize` and the Android R8 mapping are needed to interpret
obfuscated crash traces. Never archive the keystore or its passwords.

The **Build signed Android release** workflow is manually dispatched for an
existing reviewed `vX.Y.Z` tag matching `pubspec.yaml`. It waits for verification,
uses read-only repository permissions, signs AAB/split APKs, verifies their
cryptographic signatures, inspects bundled assets/model weights, and uploads
artifacts for review. It does not push version commits/tags or publish stores.
Configure its `android-release` environment with appropriate access controls
and these secrets:

- `SMARTHOME_UPLOAD_KEYSTORE_BASE64`: base64 contents of the private keystore.
- `SMARTHOME_UPLOAD_STORE_PASSWORD`.
- `SMARTHOME_UPLOAD_KEY_ALIAS`.
- `SMARTHOME_UPLOAD_KEY_PASSWORD`.

The workflow restores the key only in the runner's temporary directory, applies
mode 0600, and removes it on completion or failure. `com.example.iot_app` and
the existing Firebase configuration remain aligned. Review the permanent store
application ID and Firebase project with the owner before an initial store
submission; changing them automatically could break existing device/accounts.

## Unsigned iOS release build

Release and Profile configurations now include `ios/Flutter/Unsigned.xcconfig`.
Signing is disabled and the identity, team and provisioning-profile fields are
empty. The Podfile applies the same unsigned settings to all CocoaPods targets,
including resource bundles. Debug, Release and Profile each include the matching
CocoaPods settings before Flutter's generated settings. The project's SwiftPM
flag and build script keep the retained CocoaPods-only plugins on CocoaPods.

On macOS, after dependency preparation, either use the original command or the
artifact-producing script:

```sh
flutter build ios --release --no-codesign
# Alternatively: log the full build, verify no signature/profile, and ZIP the app.
bash tool/build_ios_unsigned.sh
```

The script produces `build/ios/SmartHome-unsigned-ios.zip` containing `Runner.app`,
plus `build/reports/ios-build.log` and the signing report. The manual **Build
unsigned iOS release** workflow and verification CI upload this ZIP. The manual
workflow replaces the old `APK & IPA .yml` at the same path, so copying the source
also replaces its version-bump/publish behavior. It needs no Apple account, team,
certificate or profile. Flutter's initial warning that signing is disabled is
expected; it does not cause a build failure and is not suppressed.

An unsigned app bundle cannot be installed on an ordinary iPhone or submitted
to App Store/TestFlight. To make a signed distribution later, override the
unsigned defaults with the owner's signing settings. For example, after preparing
Flutter's Release configuration, use Xcode on that Mac:

```sh
flutter build ios --release --config-only --no-codesign
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/ios/Runner.xcarchive archive \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM=YOUR_TEAM_ID
```

Use the owner's correct identity/profile and normal archive export options for
their distribution method; the example is not a store upload. Confirm the
local-inference memory entitlements with that signing setup.
Xcode 26 and an iOS 26 device/simulator are needed to verify the UIKit Liquid
Glass path; older toolchains exercise its fallback.

The CocoaPods permission-handler macros enable microphone, speech, Bluetooth,
and foreground location only. Camera, photo library, contacts and push
integrations were removed along with their unused plugins. Local Files imports
for models/music remain supported without requesting broad storage permission.

## Local network policy and device checks

ESP32 provisioning/control still uses plain HTTP on the local network. iOS ATS
permits local names and explicit private/link-local IPv4 ranges, while HTTPS
remains required for cloud domains. Android cannot express a CIDR range in its
network-security domain rules, so its base policy permits changing ESP32 IPs
and explicitly rejects cleartext for Firebase/Google service domains. The
application's private-address validation complements that platform limitation.
Do not remove the exception until the firmware/control protocol supports TLS.
Local network privacy prompts still apply. Android backup and device transfer
exclude private preferences, assistant memory and imported models.

Before distribution, test a **signed, shrunk release** on real Android and iOS
devices: Firebase login/logout and authorization; provisioning through the
ESP32 AP and a DHCP LAN address; BLE discovery/control/disconnection; permission
denial and retry; airplane-mode speech/TTS; music import/playback/interruption;
Gemma and GGUF import/inference/cancellation; background/resume; and offline
control. Record memory/startup/frame timings and actual APK/AAB download size.
Use `flutter build apk --release --analyze-size --target-platform=android-arm64`
with the same key to investigate binary size, and a profile build with DevTools
for runtime timings. No measured build-size or speed improvement is claimed
until those artifacts/device measurements exist.

Upstream references: [Flutter Android signing/builds](https://docs.flutter.dev/deployment/android),
[Android network security](https://developer.android.com/privacy-and-security/security-config),
[Apple local ATS exceptions](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking),
[Apple IP/CIDR exceptions](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains),
and [permission-handler setup](https://pub.dev/packages/permission_handler/versions/12.0.1).
The wrapper/distribution checksums come from [Gradle's official checksum reference](https://gradle.org/release-checksums/).
