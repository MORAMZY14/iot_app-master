# Offline training tools

Start at `../LAPTOP_TRAINING.md`. Use `train_qwen3_lora.py` for the new model and `train_gemma3_lora.py` only for the existing Gemma workflow. Preserve old checkpoints; adapters cannot transfer between model architectures.

`prepare_conversations.py` rebuilds supplied examples at a chosen token limit. `chat_laptop.py` supports temporary history, explicit preferences, and user-written corrections. `evaluate_model.py` records held-out outputs without sending device commands. `export_gguf.py` converts a merged model through llama.cpp.
