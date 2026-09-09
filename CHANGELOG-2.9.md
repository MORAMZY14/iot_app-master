# SmartHome 2.9

- Adds local Qwen GGUF imports through llamadart 0.8.22; existing Gemma .task models remain supported.
- Adds up to six recent chat exchanges, with token-aware removal of complete old turns.
- Adds editable saved preferences and a Memory sheet. Hardware command normalization excludes preferences and prior chat targets.
- Adds grammar-constrained JSON replies for GGUF and strips model thinking blocks before interpreting replies.
- Imports models through temporary files and validates GGUF headers before committing them.
- Adds a sourced English/Arabic dataset, original Egyptian Arabic follow-ups, conversation-level splits, and offline token-length preparation.
- Adds a GTX 1650 Qwen3-1.7B training entry point, offline laptop chat, explicit corrections, comparison reports, and GGUF export tools.
- Updates iOS minimum to 16.4 and Dart minimum to 3.10.7 for the additional runtime.
- Preserves the prior room UI, offline voice, and ESP32 responsiveness changes. No trained model weights are included.

- Selects only llama.cpp in llamadart build hooks to avoid duplicate LiteRT-LM libraries alongside flutter_gemma.
