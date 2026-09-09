# SmartHome 2.8.0+43

## Mobile

- Responsive photo room grid, clear selected state, accessible photo buttons, and a one-column layout for narrow screens/large text.
- Room devices appear directly below the selected room, without repeating a large photo on mobile.
- Flat content cards reduce scrolling blur work. Navigation reserves space for the center assistant button.
- Camera/gallery photos move to application files, migrating existing saved photos. Case-only room renames no longer delete the photo.
- Refreshes cannot overlap; dashboard polling pauses when the app is backgrounded. Stale refreshes cannot expire a newer pending switch command.
- Pending device commands display progress. Unassigned/disabled outputs cannot be switched from the room row.
- Assistant chat adjusts for the keyboard, has compact actions, and accepts speech after the microphone is tapped without requiring an additional wake word.
- Model loading no longer delays microphone/TTS initialization. Model replies use TextResponse.token rather than a debug representation.
- Model import/removal and generation are guarded against overlap. Failed imports attempt to restore the previous model. Native conversations are reset after two exchanges to bound context growth.
- BLE requests carry an ID echoed by new firmware, preventing an old completion from being attributed to a new command. Payloads above the firmware limit are rejected explicitly.
- Removed fabricated live energy readings; this build has no energy meter.

## ESP32

- Generic cloud requests and SSE connection setup run in a separate task. Only request/result snapshots cross the task boundary; device maps, NVS, and relays stay in loop().
- Cloud responses are bounded to 16 KiB. Local edits invalidate older in-flight configuration snapshots. Room-list HTTP requests return a cache immediately and refresh in the background.
- Registration updates status instead of overwriting the whole home node.
- Boot no longer waits for NTP. BLE commands are serviced during Wi-Fi association.
- Identical device snapshots no longer clear and rewrite NVS.
- Contradictory, negated, conditional, and exception-based power requests ask for clarification. Failed output writes do not produce a blanket success reply.
- Includes a pinned PlatformIO configuration for ESP32 Dev Module, with phone speech and ESP32 speech disabled. Arduino IDE users can still install optional ESP8266Audio/ESP8266SAM libraries.

Cloud writes remain best-effort, as in the supplied development firmware. A full queue/network outage can delay or lose cloud synchronization; local relay operation is independent. Hardware faults, GPIO state, physical loads, every customer's vocabulary, and peak TLS memory use must be checked on the real board. This package is not a production security/signing release.

## Training

- Memory-conservative GTX 1650 profile; configurable LoRA rank/sequence length.
- Resume from complete checkpoints, skip incomplete checkpoint directories, protect nonempty output directories, and check new-run dataset/settings manifests.
- Completion-only training for fresh runs; legacy resumes retain full-sequence loss.
- Separate reviewed starter evaluation set and actual-generation evaluation/laptop-chat commands.
- Standalone CPU merge with original SentencePiece tokenizer preservation.
- Pinned separate training/conversion/bundling environments; recover existing exports from the previous missing MediaPipe GenAI module error.

Android offline microphone use now requires Android 12+ and an available on-device recognizer. On older/unsupported Android devices, type commands instead; the app will not switch to a network recognizer. Android TTS selects a voice marked as not requiring network access.
