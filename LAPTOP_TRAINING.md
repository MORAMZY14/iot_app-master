# SmartHome 2.9 — Qwen, offline conversation, and learning

This upgrade adds **Qwen3-1.7B** to the phone app through GGUF, preserves your existing Gemma `.task` importer, and adds local conversation history and editable preferences. Your ESP32 keeps handling confirmed device commands; the LLM runs on the phone. Training happens on your laptop.

Your laptop: **i7-9750H, GTX 1650 4 GB, 16 GB RAM, Windows**. Qwen3-1.7B is the practical fine-tuning target here. Its multilingual instruction tuning is a better starting candidate for Arabic conversation than teaching your old 34 examples alone. This is a recommendation, not a measured improvement on your phone. Start with the smoke test: 4 GB is tight and a training run is not guaranteed to fit. Qwen3-0.6B is the smaller fallback. Phone speed and memory usage still need checking on your actual phone.

Qwen3 is Apache-2.0 licensed and supports a non-thinking mode, used here to keep spoken replies shorter and reduce latency. [Qwen model card](https://huggingface.co/Qwen/Qwen3-1.7B).

## 1. What “learning” means

| Feature | What changes | How it works offline |
|---|---|---|
| Conversation context | Temporary recent messages | The app keeps up to six exchanges and trims whole old turns to fit the model. |
| Memory | Preferences you explicitly save | Open **Memory**, enter your name/interests/reply style, and save. Edit or forget them any time. Saving starts fresh chat context. |
| Fine-tuning | Model weights | Collect reviewed examples, train a LoRA adapter on the laptop, merge and export it, then replace the phone model. |
| Speaking and listening | Speech recognition and speech synthesis | Separate phone speech services; install offline speech and voice resources where the OS supports them. |

A `.task` or `.gguf` file does **not** update its own weights while you talk. Ordinary conversations are not automatically logged for training. The laptop's `/correct` command saves only a correction you explicitly supply. Saved preferences never authorize hardware actions.

## 2. Open the correct folder in PowerShell

Extract the source ZIP to a simple path. Run commands from the project root, **not** `outputs\...\checkpoints`:

```powershell
cd C:\SmartHome\iot_app-master-master
Test-Path .\training\train_qwen3_lora.py
```

The last command should say `True`. Use Python **3.11**, not your system Python 3.14. Keep your old Gemma environment and checkpoints separate. Allow roughly 20 GB free disk space for environments, downloaded weights, merged weights, and intermediate export files; actual usage varies.

```powershell
py -3.11 -m venv .venv-qwen
.\.venv-qwen\Scripts\python.exe -m pip install --upgrade pip
.\.venv-qwen\Scripts\python.exe -m pip install torch==2.7.1 --index-url https://download.pytorch.org/whl/cu126
.\.venv-qwen\Scripts\python.exe -m pip install -r training\requirements.txt
.\.venv-qwen\Scripts\python.exe training\check_environment.py
```

The check must detect the GTX 1650, CUDA, and a working bitsandbytes 4-bit operation. A normal VirtualBox Ubuntu guest does not expose the laptop's NVIDIA GPU for this training. Use Windows directly for these steps, or properly configured WSL2 CUDA. NF4 supports this GPU generation, but supported instructions do not guarantee that every model fits its VRAM. [bitsandbytes hardware support](https://huggingface.co/docs/bitsandbytes/main/en/installation).

## 3. Download the base model once

This step uses internet and several GB of download quota. Qwen does not need the gated Gemma approval that gave you a 403 previously.

```powershell
.\.venv-qwen\Scripts\python.exe training\download_base_model.py
$base = (Get-Content .\outputs\model_download.json -Raw | ConvertFrom-Json).snapshot
Test-Path "$base\config.json"
```

The receipt records the exact downloaded revision and local snapshot. Use `$base` in all commands below. Recreate that variable from the receipt whenever you reopen PowerShell.

After packages and weights are downloaded, enforce offline access:

```powershell
$env:HF_HUB_OFFLINE = "1"
$env:TRANSFORMERS_OFFLINE = "1"
$env:HF_DATASETS_OFFLINE = "1"
```

## 4. Check the supplied dataset and try the unmodified model

The ZIP includes the prepared data; you do not need to download the large original datasets. Read `training/dataset/DATASET_CARD.md` for sources, filtering, counts, and limitations.

```powershell
.\.venv-qwen\Scripts\python.exe training\validate_dataset.py training\dataset\conversation_train.jsonl
.\.venv-qwen\Scripts\python.exe training\chat_laptop.py "$base"
```

Try English and Arabic, then a follow-up: “Explain that more simply.” Use `/quit` to exit. This laptop tool never sends relay commands. A pretrained model can already chat; fine-tuning specializes behavior and the JSON protocol.

## 5. Run a two-step training smoke test

```powershell
.\.venv-qwen\Scripts\python.exe training\train_qwen3_lora.py --base-model "$base" --output-dir outputs\qwen-smoke --max-steps 2 --save-steps 1 --skip-merge
```

This checks loading and backpropagation, not model quality. The profile uses 4-bit NF4, FP16 on the GTX 1650, batch size 1, gradient accumulation 8, checkpointing, LoRA rank 8 on q/v projections, and 512-token examples.

If this runs out of memory, close other GPU-heavy programs and retry in a new output folder. If needed, rebuild a shorter dataset without cutting answers:

```powershell
.\.venv-qwen\Scripts\python.exe training\prepare_conversations.py --tokenizer "$base" --offline --max-length 384 --output training\dataset\short384
.\.venv-qwen\Scripts\python.exe training\train_qwen3_lora.py --base-model "$base" --max-length 384 --dataset training\dataset\short384\conversation_train.jsonl --output-dir outputs\qwen-smoke384 --max-steps 2 --save-steps 1 --skip-merge
```

Use the corresponding shorter training **and dev files** for the real run. If 1.7B still does not fit, try the smaller model. Clear the offline flags for this one download, then restore them:

```powershell
Remove-Item Env:HF_HUB_OFFLINE, Env:TRANSFORMERS_OFFLINE, Env:HF_DATASETS_OFFLINE -ErrorAction SilentlyContinue
.\.venv-qwen\Scripts\python.exe training\download_base_model.py --model Qwen/Qwen3-0.6B --receipt outputs/model_small.json
$small = (Get-Content .\outputs\model_small.json -Raw | ConvertFrom-Json).snapshot
$env:HF_HUB_OFFLINE = "1"
$env:TRANSFORMERS_OFFLINE = "1"
$env:HF_DATASETS_OFFLINE = "1"
.\.venv-qwen\Scripts\python.exe training\prepare_conversations.py --tokenizer "$small" --offline --max-length 384 --output training\dataset\small384
.\.venv-qwen\Scripts\python.exe training\train_qwen3_lora.py --base-model "$small" --max-length 384 --dataset training\dataset\small384\conversation_train.jsonl --output-dir outputs\qwen-small-smoke --max-steps 2 --save-steps 1 --skip-merge
```

For its full run, use `$small`, the corresponding `small384` train/dev files, and a new output folder consistently through training, evaluation, and export. Do not resume a 1.7B adapter against a different model. The smaller model may miss conversational details; compare its replies before choosing it.

## 6. Fine-tune a fresh model

Once the smoke test fits:

```powershell
.\.venv-qwen\Scripts\python.exe training\train_qwen3_lora.py --base-model "$base" --eval-dataset training\dataset\conversation_dev.jsonl --output-dir outputs\smarthome-qwen3-1.7b --skip-merge
```

Start with the default **one epoch and learning rate 0.00005**. More epochs can overfit and reduce the base model's general ability. Training time is hardware-dependent; no duration or quality improvement has been measured for your machine.

After a restart, recover the same base path and resume:

```powershell
$base = (Get-Content .\outputs\model_download.json -Raw | ConvertFrom-Json).snapshot
.\.venv-qwen\Scripts\python.exe training\train_qwen3_lora.py --base-model "$base" --eval-dataset training\dataset\conversation_dev.jsonl --output-dir outputs\smarthome-qwen3-1.7b --resume-from-checkpoint latest --skip-merge
```

Keep the dataset, base model, sequence length and accumulation unchanged when resuming. The helper skips incomplete checkpoints. Your old Gemma `checkpoint-1250` belongs to Gemma: use **GEMMA_LEGACY_GUIDE.md** for that path, and never load it into Qwen.

## 7. Compare before accepting the fine-tune

Use the held-out test set only after making training choices on the dev set:

```powershell
.\.venv-qwen\Scripts\python.exe training\evaluate_model.py "$base" --report outputs\base-evaluation.json
.\.venv-qwen\Scripts\python.exe training\evaluate_model.py outputs\smarthome-qwen3-1.7b\adapter --report outputs\tuned-evaluation.json
.\.venv-qwen\Scripts\python.exe training\evaluate_model.py outputs\smarthome-qwen3-1.7b\adapter --dataset training\dataset\smarthome_eval.jsonl --report outputs\home-control-evaluation.json
.\.venv-qwen\Scripts\python.exe training\chat_laptop.py outputs\smarthome-qwen3-1.7b\adapter
```

JSON validity and exact command matching measure protocol compliance, not intelligence. Review answers without looking at which model produced them. Score correctness, relevance, Arabic/dialect quality, follow-up retention, and naturalness from 0–2 each. Check negations, ambiguous targets, and unconfirmed states. Keep the base model if the fine-tune regresses. All evaluation commands are local and cannot switch devices.

## 8. Merge and export GGUF

Merge on the Windows laptop first:

```powershell
.\.venv-qwen\Scripts\python.exe training\merge_adapter.py outputs\smarthome-qwen3-1.7b\adapter outputs\smarthome-qwen3-1.7b\merged
```

CPU merging needs several GB of free RAM. Preserve the adapter and base receipt.

For export, use a separate Python 3.11 Linux/WSL environment. These commands assume the project is accessible at `/mnt/c/SmartHome/iot_app-master-master`. A Linux VM can do this CPU export if you copy the **merged** folder there.

```bash
cd /mnt/c/SmartHome/iot_app-master-master
python3.11 -m venv .venv-gguf
.venv-gguf/bin/python -m pip install --upgrade pip
sudo apt-get update
sudo apt-get install -y git cmake build-essential
git clone --depth 1 --branch b6500 https://github.com/ggml-org/llama.cpp.git tools/llama.cpp
.venv-gguf/bin/python -m pip install -r tools/llama.cpp/requirements.txt
cmake -S tools/llama.cpp -B tools/llama.cpp/build -DGGML_CUDA=OFF -DLLAMA_CURL=OFF
cmake --build tools/llama.cpp/build --config Release -j 4 --target llama-quantize
.venv-gguf/bin/python training/export_gguf.py --model outputs/smarthome-qwen3-1.7b/merged --llama-cpp tools/llama.cpp --output outputs/smarthome-qwen3-1.7b-Q4_K_M.gguf
```

The pinned llama.cpp tag `b6500` includes Qwen3 conversion; its commit is `a7a98e0fffed794396b3fbad4dcdbbc184963645`. The export helper records the actual checkout and GGUF SHA-256. It preserves an intermediate F16 file, which you may delete after testing. These build dependencies need internet once. [llama.cpp conversion source](https://github.com/ggml-org/llama.cpp/blob/b6500/convert_hf_to_gguf.py).

Qwen's BPE tokenizer is exported with GGUF. **Do not use the old Gemma `bundle_task.py` or rename a GGUF to `.task`.** Existing Gemma conversion instructions remain in the legacy guide.

## 9. Build the app and import the model

Use Flutter **3.44.0** (Dart 3.12), or a compatible newer SDK. The app pins `llamadart 0.8.22` and preserves `flutter_gemma 0.16.5`. Native runtime assets are downloaded during the first build. Keep the included `hooks.user_defines.llamadart.llamadart_native_runtimes: [llama_cpp]` setting: Gemma already supplies LiteRT-LM, and loading both copies causes duplicate native-library errors. iOS now requires **16.4 or newer**; building for iOS requires a Mac/Xcode. [llamadart runtime documentation](https://pub.dev/packages/llamadart/versions/0.8.22).

```powershell
flutter pub get
flutter test
flutter build apk --debug
```

For iOS on a Mac, use `flutter build ios --debug --no-codesign` for an unsigned build. Installing on a physical iPhone still requires Apple's signing/provisioning; this project does not add production signing.

To try phone conversation before doing any training, you can use this pinned [pretrained Qwen3-1.7B Q4_K_M GGUF](https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/d7f544eead698dbd1f15126ef60b45a1e1933222/Qwen3-1.7B-Q4_K_M.gguf?download=true), a community quantization of the base model. It is about 1.11 GB (decimal) and does not include your smart-home fine-tune. Its SHA-256 is `b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897`. Training still uses the full local snapshot from step 3.

Copy `smarthome-qwen3-1.7b-Q4_K_M.gguf` to Files on iPhone or Downloads on Android. Open the voice assistant, tap **AI model → Import**, and select it. Wait for Ready, then type a message before testing the microphone. Keep space for both the original file and the app's private copy. Pretrained Qwen GGUFs can also be imported to establish a baseline; trained weights are not bundled with this source ZIP.

The phone uses CPU inference and a 2,048-token context for GGUF. Long histories lose the oldest complete exchanges. These are conservative starting settings, not a measured optimum for every phone.

## 10. Voice, memory, and further improvement

- In the assistant, tap **Test voice**. Install/download a compatible English or Arabic offline voice in the phone's settings if necessary.
- Android microphone input requires Android 12+ and an available on-device recognition service. iOS also needs on-device recognition support for the selected language. If the phone cannot recognize Arabic offline, typing still works; a smarter LLM cannot fix a missing speech recognizer.
- Open **Memory** and save up to 300 characters of preferences. Test a question about them, close/reopen the assistant, then use **Forget saved preferences** to verify deletion.
- On the laptop, `/remember My name is Dina` saves an explicit preference; `/forget` removes it. `/correct Your better answer` saves the latest conversation with your replacement answer to `outputs/reviewed_corrections.jsonl`.

Review those examples before the next training round. Corrections can contain your private information, so keep only what you intend to bake into distributable model weights.

```powershell
.\.venv-qwen\Scripts\python.exe training\add_reviewed_examples.py --corrections outputs\reviewed_corrections.jsonl --output training\dataset\conversation_train_v2.jsonl
.\.venv-qwen\Scripts\python.exe training\train_qwen3_lora.py --base-model "$base" --dataset training\dataset\conversation_train_v2.jsonl --eval-dataset training\dataset\conversation_dev.jsonl --output-dir outputs\smarthome-qwen3-v2 --skip-merge
```

A changed dataset needs a new training run. The trainer rejects oversized examples rather than silently cutting the answer; shorten long corrected conversations during review. Evaluate, merge, export, and replace the phone model again only after the new version improves your held-out conversations.

## What has and has not been done

This package changes app/runtime code, supplies a filtered dataset, and provides training/evaluation/export tools. It does not contain a newly trained Qwen model. See `VALIDATION-2.9.md` for the checks actually completed. Physical phone performance, offline speech availability, relay behavior, and a full CUDA training run require testing on your equipment. The prior ESP32 responsiveness and room UI improvements remain included.


## Validation result for this source revision

18 Flutter tests, 15 Python tests, and 16 C++ control-intent assertions passed. Dart analysis found no errors. A real Qwen3-1.7B GGUF launch passed after correcting duplicate runtime libraries. The baseline used the saved name in English but missed the Arabic name/dialect follow-up, so this is not a quality benchmark or a trained model. Read `VALIDATION-2.9.md` before interpreting the smoke test as conversation-quality evidence.
