# SmartHome 2.8 — train on your laptop, run offline on the phone

This guide is for your Intel i7-9750H, NVIDIA GTX 1650 **4 GB**, and **16 GB RAM**. The updated archive contains source code and training examples, **not trained model weights**. Nothing has been trained on your laptop by this chat.

The laptop fine-tunes Gemma. The phone runs the exported model, recognizes speech using supported installed offline language packs, and speaks the reply. Your ESP32-D0WD-V3 runs device matching, sensors, HTTP/BLE, and relay control; a Gemma model does not fit its 4 MB flash. The laptop does not need to stay on after importing the model into the phone.

Initial package/model downloads and Gemma access approval need Internet. After the necessary files are cached, training/inference can run locally. Existing Firebase login/home synchronization in this project is separate from the offline assistant and remains in place.

## 1. Extract into a short path

Extract the archive into `C:\SmartHome`. The **project root** is the folder containing `pubspec.yaml`, `lib`, `training`, and `esp32_firmware`.

Open PowerShell in that folder:

```powershell
Set-Location C:\SmartHome\iot_app-master-master
Get-Item .\pubspec.yaml
Get-Item .\training\train_gemma3_lora.py
```

Adjust the first path to your extraction location. Do not run the training script from `outputs\...\checkpoints`; it is in `training` at the project root. Keep existing outputs/checkpoints before replacing source files.

## 2. If you already finished training, skip retraining

Look for either:

- `outputs\smarthome-gemma3-1b\adapter\adapter_config.json`, or
- `outputs\smarthome-gemma3-1b\checkpoints\checkpoint-1250\adapter_config.json`, or
- a complete `outputs\smarthome-gemma3-1b\merged` directory containing model weights.

If `merged` already exists and has weights, `config.json`, and `tokenizer.model`, go to step 7. If you only have an adapter/checkpoint, use step 6. If training was interrupted, use step 5 in your original working Python environment.

## 3. Fresh Windows training environment

For a new run, install Python **3.11, 64 bit**. Python 3.14 is not the version used by this kit. An ordinary VirtualBox Ubuntu VM normally has no access to your GTX 1650; use native Windows or WSL2 with NVIDIA GPU support for training. A VM can do CPU conversion later.

Use these commands in **PowerShell**. Calling the venv Python directly avoids activation-policy problems:

```powershell
py -3.11 -m venv .venv-train
.\.venv-train\Scripts\python.exe -m pip install --upgrade pip
.\.venv-train\Scripts\python.exe -m pip install torch==2.7.1 --index-url https://download.pytorch.org/whl/cu126
.\.venv-train\Scripts\python.exe -m pip install -r training\requirements.txt
.\.venv-train\Scripts\python.exe -m pip check
.\.venv-train\Scripts\python.exe training\check_environment.py
```

The checker must report your GTX 1650, CUDA, and **4-bit CUDA forward/backward: OK**. `nvidia-smi` alone does not establish that the Python environment has a CUDA build. Your newer NVIDIA driver can run the CUDA 12.6 PyTorch wheel; do not install a separate CUDA toolkit merely because `nvidia-smi` shows a different CUDA version. [Official PyTorch wheel commands](https://pytorch.org/get-started/previous-versions/), [bitsandbytes hardware requirements](https://huggingface.co/docs/bitsandbytes/main/en/installation).

If your previous `.venv-train` already trains successfully, preserve it for resuming old checkpoints. Changing PyTorch/TRL versions, the dataset, or accumulation settings mid-resume can change results or break checkpoint loading.

## 4. Obtain model access, validate data, then train

Open [google/gemma-3-1b-it](https://huggingface.co/google/gemma-3-1b-it), sign in, and accept the Gemma terms with the account you will use below. A 403/GatedRepoError means that account has not been granted access. Do not put your Hugging Face token inside source files.

This pinned Hugging Face Hub version uses `huggingface-cli`:

```powershell
.\.venv-train\Scripts\huggingface-cli.exe login
.\.venv-train\Scripts\python.exe training\validate_dataset.py
```

The original training set contains **34 examples**. It is a starter set, not enough evidence of a reliable general bilingual assistant. The separate `smarthome_eval.jsonl` has **24 held-out checks**. Keep those examples out of training; add reviewed training examples for your own room/device names, Egyptian Arabic, ambiguous requests, and safe refusal to guess.

First run a small memory test in a **separate folder**:

```powershell
.\.venv-train\Scripts\python.exe training\train_gemma3_lora.py --profile gtx1650 --max-steps 2 --save-steps 1 --skip-merge --output-dir outputs\smoke-gtx1650
```

Then start the real run in a new folder:

```powershell
.\.venv-train\Scripts\python.exe training\train_gemma3_lora.py --profile gtx1650 --epochs 3 --eval-dataset training\dataset\smarthome_eval.jsonl --skip-merge --output-dir outputs\smarthome-gemma3-1b-gtx1650
```

The GTX profile uses 4-bit weights, FP16 computation on your GPU, batch size 1, accumulation 8, rank-8 adapters on the attention Q/V projections, gradient checkpointing, and 384-token examples. It is a conservative starting configuration, **not a guarantee that every 4 GB system has enough free memory**. Close games and other GPU workloads. If the memory test fails, do not start the full run. The script refuses to silently cut off training examples longer than the sequence limit.

Checkpoints are saved every 10 optimizer steps, with the newest three retained; the final adapter is also saved. With only 34 examples, the training run is short and the evaluation has limited coverage. The script refuses to overwrite a nonempty output folder.

## 5. Resume after restarting your laptop

For a new GTX-profile run, return to the project root and run:

```powershell
.\.venv-train\Scripts\python.exe training\train_gemma3_lora.py --profile gtx1650 --epochs 3 --eval-dataset training\dataset\smarthome_eval.jsonl --skip-merge --output-dir outputs\smarthome-gemma3-1b-gtx1650 --resume-from-checkpoint latest
```

For your older `checkpoint-1250`, use the original environment and original training settings. Example **only if the old run used the supplied standard defaults** (768 tokens, accumulation 8, three epochs):

```powershell
.\.venv-train\Scripts\python.exe training\train_gemma3_lora.py --max-length 768 --gradient-accumulation 8 --epochs 3 --skip-merge --output-dir outputs\smarthome-gemma3-1b --resume-from-checkpoint outputs\smarthome-gemma3-1b\checkpoints\checkpoint-1250
```

Replace those settings with the ones you actually used. The adapter architecture is read from the checkpoint. New-run manifests check the dataset hash and key settings; legacy checkpoints do not contain all of that information.

A complete resume checkpoint needs adapter weights/config, `trainer_state.json`, `optimizer.pt`, and `scheduler.pt`. `latest` skips incomplete checkpoint directories. An adapter-only folder is still usable for merging, but cannot restore the full optimizer state. Do not type `trainer.train(...)` into PowerShell: that is Python code, and the new command-line option handles it for you.

## 6. Test the adapter and merge without retraining

Laptop conversation test (does not send commands to the ESP32):

```powershell
.\.venv-train\Scripts\python.exe training\chat_laptop.py outputs\smarthome-gemma3-1b-gtx1650\adapter
```

Type `/quit` to exit. The first base-model load may download missing cached weights.

Evaluate generated JSON and proposed commands:

```powershell
.\.venv-train\Scripts\python.exe training\evaluate_model.py outputs\smarthome-gemma3-1b-gtx1650\adapter --report outputs\evaluation.json
```

Review every failure and the actual replies. Exact command matching is deliberately strict; this report does not measure speech quality or physical relay behavior.

Merge into a new folder on CPU:

```powershell
.\.venv-train\Scripts\python.exe training\merge_adapter.py outputs\smarthome-gemma3-1b-gtx1650\adapter outputs\smarthome-gemma3-1b-gtx1650\merged
```

For your old adapter/checkpoint, substitute its path; no training is rerun. Close memory-heavy applications while merging. The helper preserves the original `tokenizer.model` needed by the mobile bundler, including when the fast tokenizer only saved `tokenizer.json`.

## 7. Convert on Linux/WSL — separate environment

The following are **Bash commands in Ubuntu/WSL**, not PowerShell. Use Python 3.11 with venv support. Work from the project root; on WSL, `C:\SmartHome` is `/mnt/c/SmartHome`. Conversion is usually faster in WSL's Linux filesystem than under `/mnt/c`.

Copy the completed merged model into this workspace if training happened elsewhere. Internet is required to install conversion packages. Keep all of these environments separate.

```bash
python3.11 -m venv .venv-convert
.venv-convert/bin/python -m pip install --upgrade pip
.venv-convert/bin/python -m pip install -r training/requirements-convert.txt
.venv-convert/bin/python training/convert_to_tflite.py outputs/smarthome-gemma3-1b-gtx1650/merged outputs/smarthome-gemma3-1b-gtx1650/litert --prefill-seq-len 512 --kv-cache-max-len 2048
```

This keeps the existing MediaPipe `.task` runtime and uses dynamic INT8 conversion for the phone CPU. The app requests 1536 context tokens, below the exported 2048-token cache. Conversion is CPU work and may be slow; do not mistake a quiet terminal for a freeze. Free RAM, sufficient disk space, and swap may be necessary on a 16 GB machine. This exact model conversion has not been executed in this chat because the archive contains no trained weights. [Google's Gemma conversion guide](https://ai.google.dev/gemma/docs/conversions/hf-to-mediapipe-task).

## 8. Fix the previous MediaPipe bundler error

Do **not** install an unpinned current MediaPipe into your conversion environment. The legacy `.task` bundler used here is present in **MediaPipe 0.10.21**. Use a fresh Python 3.11 environment:

```bash
python3.11 -m venv .venv-bundle
.venv-bundle/bin/python -m pip install --upgrade pip
.venv-bundle/bin/python -m pip install -r training/requirements-bundle.txt
.venv-bundle/bin/python -c "from mediapipe.tasks.python.genai import bundler; print('Bundler import OK')"
```

Find the actual exported filename:

```bash
ls outputs/smarthome-gemma3-1b-gtx1650/litert/*.tflite
```

Use that exact filename below in place of `ACTUAL_MODEL.tflite`:

```bash
.venv-bundle/bin/python training/bundle_task.py outputs/smarthome-gemma3-1b-gtx1650/litert/ACTUAL_MODEL.tflite outputs/smarthome-gemma3-1b-gtx1650/merged/tokenizer.model outputs/smarthome-assistant.task
```

If your previous export is already in `outputs/smarthome-gemma3-1b/litert-final/`, use that `.tflite` and the matching tokenizer; **you do not need to train or convert again just to fix bundling**. Avoid a wildcard when multiple exports exist. The script checks the TFLite header, writes a temporary output, and reports a SHA256 checksum. [MediaPipe 0.10.21 bundler source](https://github.com/google-ai-edge/mediapipe/blob/v0.10.21/mediapipe/tasks/python/genai/bundler/llm_bundler.py).

## 9. Build the updated phone app and import

From the project root, with Flutter installed:

```powershell
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=ESP32_LOCAL_IP=192.168.1.50
```

Use your controller's actual IP. `192.168.1.50` is only an example; this is a local controller address, not an AI server. You can also use the app's BLE connection.

Copy `smarthome-assistant.task` to your phone. Open the center assistant button → **AI model** → import the `.task` file. Keep the app open during the copy/load and allow several GB of free storage. Test typed English/Arabic conversation first, then test voice and actual device names with Internet disabled but local Wi-Fi or Bluetooth enabled.

Gemma fine-tuning does not train the speech recognizer or TTS voice. Offline speech availability depends on the phone, OS, and installed language/voice packs; test Arabic separately. Typed commands remain available if offline recognition is unsupported. The model manager is mobile-only in this project; a Chrome preview cannot import this `.task` model.

For a development APK: `flutter build apk --debug`. Your unsigned iOS workflow still requires a Mac/Xcode; follow `DEPLOYMENT.md`. No production signing identity is included.

## 10. Flash and check the ESP32

Open `esp32_firmware/SmartHomeOffline/SmartHomeOffline.ino` in Arduino IDE. Keep **CloudTransport.h** and **ControlIntentGuard.h** beside the sketch. Do not flash the separate optional example in `esp32_offline_assistant`.

The included `platformio.ini` fixes versions for an ESP32 Dev Module compilation with phone speech and a 3 MB application partition (4 MB flash, no OTA):

```powershell
py -m pip install platformio
py -m platformio run -d esp32_firmware\SmartHomeOffline
py -m platformio run -d esp32_firmware\SmartHomeOffline --target upload --upload-port COM3
py -m platformio device monitor --port COM3 --baud 115200
```

Use your actual board/port. COM3 is the port from your earlier setup. Your GPIO and PCF8574 connections remain as documented in the firmware README. If Arduino IDE reports a `bootloader.bin ... was unexpected` path error, extract to the short path above and select the ESP32 board again.

Confirm version **2.8.0-responsive-local** through BLE status or `GET /api/ellie/capabilities`.

Check these behaviors on the actual board:

1. Switch one device on/off over LAN, then repeat over BLE with phone Wi-Fi off.
2. Disconnect the router's Internet connection but keep local Wi-Fi; repeat while waiting for cloud retries.
3. Say “turn off TV and Desk Lamp” using your exact configured names. Check both outputs.
4. Say “do not turn off the fridge”, “turn on TV and turn off Fan”, and “turn off all except TV”. The controller should ask for a simpler request and change nothing.
5. Disconnect an I/O module and issue a command; a failed write must not be announced as a successful action.
6. Verify existing rooms/devices remain after controller registration and app restart. Check both themes, large text, photo changes, and the assistant with the keyboard open.

Compilation, host tests, and UI tests cannot establish hardware responsiveness or model quality. `CHANGELOG-2.8.md` and `VALIDATION.md` describe the changes and the actual checks completed for this package.

Android offline microphone use now requires Android 12+ and an available on-device recognizer. On older/unsupported Android devices, type commands instead; the app will not switch to a network recognizer. Android TTS selects a voice marked as not requiring network access.
