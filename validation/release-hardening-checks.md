# Release hardening checks — 1 October 2026

| Check | Result |
| --- | --- |
| `python3 tool/verify_build_policy.py` | Passed after UI integration removed bundled-photo references |
| Python policy script bytecode compilation | Passed |
| Bash syntax for preparation/integration scripts | Passed |
| Android manifest/network/backup XML parsing | Passed |
| iOS Info.plist and inference entitlement plist parsing | Passed |
| Both workflow YAML files and immutable action references | Passed |
| Retained direct dependency versions versus original lock | All 19 non-SDK versions match exactly |
| Gradle 8.14 wrapper bootstrap checksum | Matches official `7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172` |
| Artifact policy negative fixtures | Correctly rejected bundled-photo APK, bundled-GGUF AAB and unsigned AAB |
| `tool/prepare_dependencies.sh --refresh` | Exited 127 with an actionable missing-Flutter message |
| `verify_build_policy.py --resolved` | Correctly reports the original lockfile is pending real Flutter refresh |

The wrapper JAR was downloaded from Gradle's official repository and verified
against its published checksum before being copied into the source. The Gradle
version remains 8.14, with a checksum-verified binary-only distribution. The
Flutter 3.44.0 archive HEAD request returned HTTP 404 in this environment. There
is no Flutter/Dart, Android SDK build tools, Ruby or Xcode command available on
PATH here for mobile compilation. Java and `keytool` are present; `jarsigner`
is absent from PATH.

These are source/configuration checks and synthetic ZIP rejection checks.
Flutter tests, Dart analysis/formatting, package/native graph resolution,
Gradle/Kotlin compilation, the real missing-key failure, R8 compilation,
Swift compilation, actual signature verification, and signed-device/hardware
behavior have **not** been exercised in this workspace. No APK/AAB/IPA or
measured application size/speed improvement is claimed. The prepared CI jobs
perform those available build checks with the pinned SDK, refreshing and then
enforcing the real lockfile in the same job and attaching the resolved graph.

Release setup and device validation are documented in `docs/RELEASE.md`.
