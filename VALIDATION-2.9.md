# SmartHome 2.9 — completed checks

Checked on 8 September 2026 with Flutter 3.44.0 / Dart 3.12.0 and Python 3.12 in this workspace. The laptop instructions target a separate Python 3.11 environment.

| Check | Result | Evidence |
|---|---|---|
| Flutter package resolution | Passed; resolved lockfile included | `validation/pub-get-2.9.txt` |
| Flutter tests | 18 passed after the runtime packaging fix | `validation/flutter-tests-2.9.txt` |
| Room-card visual checks | Passed at 320 px in light/dark themes; large text actions remain reachable | Included in Flutter tests and `test/goldens/` |
| Dart analysis | 0 errors, 12 warnings, 110 informational diagnostics; analyzer exits 2 because warnings remain | `validation/dart-analyzer-2.9.txt` |
| Python regression tests | 15 passed | `validation/python-tests-2.9.txt` |
| Dataset protocol and split checks | 1,383 train, 164 dev, 181 test examples; no detected cross-split conversation overlap | Python tests and `training/dataset/dataset_manifest.json` |
| Real tokenizer length checks | Every supplied example fits 512 tokens; train/dev maxima 512, test maximum 511. The final file hashes match those checked files | Dataset manifest; tokenizer verification performed during preparation |
| Native Qwen3-1.7B GGUF launch | Passed using the app's actual dependencies, Linux CPU, and imported pretrained weights | `validation/native-qwen17-2.9.txt` and `validation/model-smoke-manifest.json` |
| C++ control-intent checks | 16 host assertions passed | `validation/control-intent-2.9.txt` |
| Offline app/firmware integration contract | Passed | `validation/integration-contract-2.9.txt` |

## Native packaging fix

A real launch initially failed because flutter_gemma and llamadart both included LiteRT-LM libraries with identical filenames. `pubspec.yaml` now uses the package's supported `llamadart_native_runtimes: [llama_cpp]` hook. Qwen uses llama.cpp; the existing Gemma importer retains its plugin. The subsequent launch passed asset verification, loaded the model, and generated two JSON replies.

The first Linux setup emitted archive ownership warnings from flutter_gemma after verifying its download checksums. The Qwen launch and subsequent Flutter tests completed. No dependency integrity checks were disabled.

## What the model check actually showed

The tested GGUF is an unmodified community quantization of Qwen3-1.7B, not a model trained on the supplied dataset. The smoke script uses a short test system prompt with a saved name, then English and Arabic requests. It verifies loading, generation, JSON structure and null hardware commands; it is not a conversational quality benchmark.

- English name request: the model replied `Hello Dina!`, using the saved name.
- Egyptian Arabic follow-up: it replied `مرحباً بمصر، باسمك المفضل.` This missed the requested name and natural Egyptian phrasing.
- The smaller 0.6B model also generated valid JSON in an earlier standalone check but missed the Arabic name follow-up.

These results are why the guide requires comparing base and fine-tuned replies and reviewing dialect quality. Model support, valid JSON, a larger dataset, and memory context do not establish improved intelligence. No measured improvement from fine-tuning is claimed.

## Work that still needs the user's equipment

- Run the two-step CUDA training test on the GTX 1650 4 GB before attempting a full run. CUDA training, adapter evaluation, merging, and GGUF export were not executed here.
- Test Qwen and the preserved Gemma importer on the actual Android/iPhone build. No APK, signed iOS package, phone benchmark, or phone microphone/TTS test was produced here.
- Verify offline speech resources for the selected language. The LLM and speech recognizer are separate components.
- Build, flash and exercise the ESP32 firmware on the actual board. Its source is unchanged from the prior 2.8 responsiveness changes. `VALIDATION.md` records the earlier full-sketch syntax-only check and the blocked full PlatformIO build; it does not establish final flash size or physical behavior.
- Check confirmed relay states, network loss, BLE timing, and I/O failures before relying on the system.

No trained Qwen weights are included in the source ZIP. The LLM has no cloud inference fallback; other original application features still include Firebase services.
