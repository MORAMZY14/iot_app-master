# SmartHome mobile production modernization

The user requests a complete review of the supplied Flutter source, a modern UI made from real controls rather than pictures, and a faster, smaller mobile app. Preserve the existing accounts, device/room management, ESP32 local HTTP/BLE/cloud controls, English/Arabic offline voice, imported Gemma/GGUF models, music, firmware and training tools.

## UI

Use Material 3 with a coherent blue accent, neutral surfaces, readable text, generous touch targets, rounded cards and light/dark themes. Replace all bundled house and room photographs and image picking with icon-based room cards. Keep the launcher logo source, but do not bundle unrelated images into the app. Keep native iOS navigation where supported; use a solid, lightweight Flutter navigation surface elsewhere. Modernize shared components, account forms, dashboard rooms/devices, energy empty states and setup/settings screens. Make content scrollable at narrow widths and large text sizes. Respect reduced motion. Do not show fake telemetry or energy readings.

## Reliability and performance

Authenticate Firebase REST calls for the configured database only; never send ID tokens to local ESP32 endpoints. Invalidate polling reads on refresh, prevent overlapping requests, pause background polling, discard results after provider disposal/account changes, and make connection failures explicit. Keep immediate optimistic device feedback with failure rollback. Distinguish a submitted cloud command from physical device confirmation. Avoid initializing all tab pages before they are visited. Request permissions when the corresponding feature is used. Remove forced startup waits and make startup failures recoverable.

Fix confirmed account/ownership lifecycle, BLE cancellation and assistant command/runtime races. Preserve pending verification so users can resend verification email. Do not deploy Firebase rules or rewrite firmware authentication without verified backend context.

## Release and size

Remove unused dependencies identified by source/native import audit; preserve both native inference engines. Configure actual Android release signing rather than debug signing, code/resource shrinking, split ABI APK and AAB workflows, symbols outside the shipped binary, and pinned toolchain verification. Keep local HTTP access necessary for ESP32 with platform-specific transport exceptions and accurate permission declarations. Do not publish unsigned iOS archives as production releases.

## Verification and delivery

Run available static, parser, native and Python checks. Add meaningful regression coverage for changed auth/transport/polling/assistant behavior and component accessibility. Run Flutter checks/builds if an SDK is available. If the environment cannot run them, make the limitation explicit and provide a CI path that actually runs analysis/tests/builds. Do not label unbuilt source a signed or device-verified production binary. Record exact asset/dependency savings; do not invent final APK/IPA size or measured FPS/startup improvements. Deliver the complete updated source archive with concise release instructions and a findings/verification record.
