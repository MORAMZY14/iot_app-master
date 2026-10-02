# SmartHome production modernization implementation plan

> **For agentic workers:** Use the independent-domain parallel workflow for release, assistant and auth/BLE changes; the primary agent owns shared UI, dashboard and integration. All changes are within the user's authorized source update.

**Goal:** Modernize and optimize the existing mobile app while correcting confirmed production defects.

**Architecture:** Preserve the existing Riverpod services and mobile plugins. Consolidate UI in shared components, introduce an authenticated HTTP boundary, and repair polling/lifecycle without replacing device protocols.

**Tech stack:** Flutter/Dart, Firebase Auth/Realtime Database, ESP32 HTTP/BLE, Gemma and llama.cpp local inference.

**Spec:** ../specs/2026-10-01-production-modernization-design.md

## Global constraints

- No bundled UI photographs, fake telemetry, cloud inference fallback or model weights.
- Preserve both Gemma and GGUF imports, voice, music, firmware and training tools.
- Never send Firebase tokens to local endpoints or debug-sign a production release.
- Report unavailable mobile builds/device checks explicitly.

## Review focus

- Account switching must not reuse previous telemetry, notifications or model command context.
- Polling must refresh rather than reuse a cached completed future and must stop in the background.
- Partial scene/device failures must not be reported as completed physical changes.
- Large text and narrow screens must retain usable device controls and form actions.
- Native assistant sessions must not overlap load/import/remove or survive disposal incorrectly.

## Tasks

### 1. Audit and release hardening

- [x] Trace dependency imports and native configuration against the supplied archive.
- [x] Configure upload-key signing, shrinking, transport permissions and pinned verify/release CI.
- [x] Remove only unused dependencies and bundled photo declarations; retain features.
- [x] Verify configuration and document toolchain/build limitations.

### 2. Auth/BLE and offline assistant correctness

- [x] Pin concrete auth ownership, BLE cancellation and assistant command/runtime failures with regression cases.
- [x] Implement fixes within auth/BLE and assistant domains.
- [x] Review integration with account verification and device IDs.
- [x] Run available checks, retain meaningful mobile regression tests for CI.

### 3. Shared UI and source transport

- [x] Rebuild shared design components and room/device cards using Material widgets.
- [x] Modernize sign-in/splash/setup/settings, readable text and theme colors.
- [x] Add an exact-host authenticated HTTP adapter and token-isolation tests.
- [x] Repair fresh polling, background pause, account invalidation and lazy tab creation.

### 4. Integration, verification and packaging

- [x] Review all changed source and run available Dart syntax/static, firmware and Python checks.
- [x] Record the missing Flutter SDK; supplied CI performs analysis/tests/builds. No mobile execution was possible here.
- [x] Obtain an independent whole-change review and address confirmed blockers.
- [x] Record measured source/asset savings and remaining release requirements.
- [x] Prepare the complete updated source archive for final delivery.

## Final qualification

Source/configuration and available native/Python checks passed. Flutter type analysis, UI rendering, native mobile builds/signing and device behavior remain unverified. Firmware/backend authorization, TLS, ownership unbind and large BLE response framing remain production blockers documented in `docs/PRODUCTION_REVIEW.md`.
