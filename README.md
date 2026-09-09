# SmartHome 2.9

Flutter smart-home app with a private offline assistant and ESP32 firmware.

Start with **[LAPTOP_TRAINING.md](LAPTOP_TRAINING.md)** for the Qwen3-1.7B workflow on the GTX 1650 4 GB laptop. It covers downloads, offline chat, fine-tuning, checkpoint resume, evaluation, GGUF export, and phone import.

This version adds Qwen GGUF support, conversation context, editable saved preferences, and reviewed laptop corrections for later training. Existing Gemma `.task` imports, room UI improvements, offline voice checks, local HTTP/BLE controls, and the optimized ESP32 firmware remain included.

- Dataset: `training/dataset/DATASET_CARD.md`
- Completed checks and limitations: `VALIDATION-2.9.md`
- Existing Gemma checkpoints and `.task` conversion: `GEMMA_LEGACY_GUIDE.md`
- ESP32 setup: `esp32_firmware/SmartHomeOffline/README.md`

The LLM runs on the phone; training runs on the laptop. The original 4 MB ESP32 runs the device firmware, not the language model. No trained Qwen weights are included. The assistant has no cloud inference fallback; other existing app features still include Firebase services.
