# SmartHome 2.12 production review

Source baseline: the supplied SmartHome 2.11 archive. Updated mobile version:
**2.12.1+48**. Build patch date: **2 October 2026**; broader review date: **1 October 2026**.

## Result

The source has been modernized and hardened for a production build workflow.
It has not been compiled, rendered by Flutter, signed, or verified on a phone
in this workspace. The firmware/backend security items below are release
blockers; this package is not a certification that the complete system is safe
for public deployment.

## Changes

| Area | Implemented behavior |
| --- | --- |
| UI | Material 3 theme, neutral surfaces, real icon/room/device cards, readable labels, usable switches and navigation, responsive room layouts, light/dark/system appearance persisted locally |
| Images | Removed six bundled room/house photographs and photo import/storage; retained the native launcher-logo build input |
| Startup | First Flutter frame without a forced splash delay; recoverable Firebase setup error; AI runtime and feature permissions initialized when needed |
| Runtime | Lazy tab creation, reused HTTP connections, parallel room/device/cloud metadata reads, serialized fresh polling, background pause, refresh on resume and account/disposal guards |
| Telemetry | Real readings and truthful energy-meter empty state; energy node is forwarded; cloud command submission is distinguished from physical confirmation; failed device actions roll back and propagate to scenes |
| Firebase REST | Current-user ID token only for the configured database origin; own-UID checks; no credential forwarding on redirects; redacted connection/body-stream errors; checked account/profile responses |
| Registration | Conditional ownership claims after profile/verification setup; interrupted final claims are reconciled; an ambiguous committed claim preserves account/profile instead of orphaning the firmware's cached UID |
| Controller identity | Local control checks the linked unique code; authenticated BLE connections verify the linked code before commands; account changes disconnect BLE and close account-owned pages/sheets |
| BLE | Generation checks, native deadlines and queue-free disconnect, serialized command/response exchanges, no echoed-request acknowledgments, stale-sequence rejection, long-write support for the current firmware |
| Assistant | Scope-preserving model proposals, shared initialization, awaited Gemma setup, mutation/inference exclusion, account-isolated history/preferences, discarded old-session replies, speech cancellation and listener lifecycle fixes |
| Files/music | Streamed atomic imports, owned-directory deletion only, serialized playback transitions, TTS interruption behavior and partial-import retention |
| Release | Pinned toolchain and dependency versions, authentic checksum-pinned Gradle wrapper, private upload-key requirements, R8/resource shrinking, AAB/split ABI artifacts, native transport/backup permissions and reviewable CI |
| Build patch | Dashboard login import corrected; Flutter 3.47.6, SDK 36, Gradle 9.1.0, AGP 9.0.1, Kotlin 2.3.20 and Google Services 4.5.0; unsigned iOS Runner/Pods settings, complete xcconfig includes, verbose build logs and unsigned `.app` ZIP workflow |

Controller switching and linked-account erasure now stop with a clear unbind
requirement. Removing a cloud ownership entry does not clear this firmware's
NVS owner and cannot truthfully complete a transfer or erase device-backed data.
Saved assistant preferences are now keyed by account. Old unscoped preferences
are not assigned to an account without evidence of their owner; users should
re-enter those preferences. Imported model/music files remain device-local.

## Measured reductions

- Direct non-SDK dependencies: **41 to 19**, removing **22** unused packages.
  Retained versions match their original resolved versions; there was no plugin
  upgrade hidden in dependency pruning.
- Removed bundled photographs: **6 files / 13,870,727 bytes** (**13.23 MiB**).
- Old photo widgets/stores, obsolete UI helpers, stale native registrants and
  screenshots of the replaced UI were removed. Regression tests remain source
  inputs rather than app UI or bundled demonstration content.
- Final installed APK/IPA size, startup latency, frame timings and native-model
  memory use have not been measured. Source/archive savings do not establish
  the installed-app size or a numeric speed improvement. Both AI engines remain
  included; weights are imported by users rather than bundled in the app.

## Verification actually performed

| Check | Evidence/status |
| --- | --- |
| Dart syntax parsing | 59 files in `lib`, `test`, and `tool`; no grammar errors using tree-sitter-dart. This is not Dart type analysis. |
| Mobile source/build policy | `python3 tool/verify_build_policy.py` passed |
| Native configuration | Android XML and iOS plist/entitlement parsing; the Xcode project and all three CI workflow YAML files parsed; Runner Debug/Release/Profile xcconfig references checked; action references are immutable |
| Shell syntax | Dependency preparation, offline integration and unsigned iOS scripts passed `bash -n` |
| Unsigned build script | Five mocked-tool scenarios confirm compiler failure propagation, signed-app rejection, unrelated signing-error rejection, provisioning-profile rejection and unsigned artifact creation. These are script checks, not native builds. |
| Offline app/firmware contract | `bash tool/validate_offline_integration.sh` passed; BLE UUIDs match; 34 valid command-training conversations |
| Firmware intent guard | C++17 build with warnings as errors; 16 assertions passed |
| Training tools/data | `python3 -m unittest discover -s training/tests -v`: 15 tests passed |
| Independent source review | Raised account-history, rename/disconnect, initialization, credential-redaction, late-result and ambiguous-claim defects; their source fixes and regression cases are included |
| Dependency refresh | Exited 127 with a missing-Flutter message; original lockfile is explicitly pending authentic refresh |
| Flutter format/analyze/tests | Not run: Flutter/Dart SDK unavailable. All new and retained Dart tests remain unverified. |
| Mobile compilation/signatures/UI | Not run: no Flutter mobile toolchain, signing key or Xcode/device session. No APK/AAB/IPA or Flutter-rendered screenshot is supplied. |

CI runs real dependency resolution, analyzer warnings, Flutter tests, firmware
contracts and Android/iOS compilation on the pinned toolchain. Its existence
is not evidence that a CI run or signed release has succeeded. Follow
[RELEASE.md](RELEASE.md) and retain the actual reports before distribution.

## Remaining production blockers

1. **Firmware/cloud authorization.** The supplied firmware sends Firebase REST
   traffic without a per-device authenticated identity. The uploaded project
   contains no verifiable deployed RTDB authorization rules. Client ID-token
   checks and conditional ownership writes do not replace server enforcement.
   Provision a trusted device identity and scoped server rules/backend before
   public deployment. Do not simply deny all unauthenticated traffic without
   migrating the firmware: its current cloud sync would stop.
2. **Firmware TLS and local control.** The preserved firmware uses `setInsecure()`
   for cloud TLS, and HTTP/BLE physical control lacks a cryptographically
   authenticated device-command protocol. Unique-code matching prevents an
   accidental wrong-controller connection but does not prove identity against
   an attacker. Implement certificate validation and authenticated local/cloud
   commands in the firmware with the target ESP32 toolchain, then verify them
   on hardware. Phone-side private-host checks complement transport policy;
   they do not secure an untrusted network.
3. **Safe ownership transfer/erasure.** Firmware persists its UID in NVS and does
   not revalidate it on a cloud unbind. A trusted unbind/rebind and erasure flow
   is needed. The app blocks misleading transfers and linked-account deletion
   until that flow exists; it never claims those operations succeeded.
4. **Large BLE replies.** The current NimBLE characteristic defaults to a
   512-byte attribute. Larger device inventories/Wi-Fi scan responses need
   firmware paging or framing and physical-device verification. Outgoing
   command length and native deadlines are guarded, but the app cannot add
   server-side paging to an unchanged firmware response.
5. **Build and release evidence.** Resolve/retain the real dependency and
   CocoaPods graphs; run Flutter analysis/tests, render narrow/large-text and
   light/dark screens, and exercise a signed/shrunk Android build plus signed
   iOS build on real devices. Check login/logout, interrupted registration,
   ownership rules, provisioning, BLE, offline voice/music, both model formats,
   background/resume, memory pressure, and measured package/startup/frame costs.

The existing Firebase project, application IDs, firmware and training resources
were preserved to avoid silently changing accounts or device contracts. The
backend/firmware migration and signing credentials require the actual owner's
infrastructure and hardware; no remote deployment was performed.
