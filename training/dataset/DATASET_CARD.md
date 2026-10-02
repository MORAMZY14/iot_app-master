# Conversation dataset — SmartHome 2.9

This is adaptation data for a pretrained assistant, not training from scratch.

| Split | Examples | English | Arabic | Multi-turn examples |
|---|---:|---:|---:|---:|
| train | 1383 | 855 | 528 | 106 |
| dev | 164 | 106 | 58 | 14 |
| test | 181 | 106 | 75 | 14 |

A multi-turn example predicts the final assistant response given earlier exchanges. Multiple examples may come from the same source conversation. The manifest records distinct conversations and SHA-256 hashes. The separate `smarthome_eval.jsonl` retains 24 additional home-control checks.

## Sources and permissions

- [Smol-SmolTalk](https://huggingface.co/datasets/HuggingFaceTB/smol-smoltalk): only the `smol-magpie-ultra-short` synthetic subset, Apache-2.0. Source revision `f73fe857d519ff6ac5af2ea67c4d3834da7b8bcc`; selected from its first training parquet shard.
- [Aya Dataset](https://huggingface.co/datasets/CohereLabs/aya_dataset): Standard Arabic (`arb`), original human annotations only, Apache-2.0. Source revision `f9ea04583f02a8f86404ff6c58bf75fe637df8a2`. Contributor identifiers are not included.
- `conversation_data.py`: 24 original synthetic parallel English/Egyptian-Arabic scenarios, with follow-up questions, corrections, preferences, and honest limitations. Two supervised examples per language per scenario; not human-collected speech.
- The original 34 project examples remain unchanged in `smarthome_train.jsonl` for old Gemma checkpoints. A protocol-compatible copy is included in the new mixture.

## Processing

Public examples are reformatted into the app JSON envelope with device_command=null. Filters remove overly long turns, empty/malformed rows, exact duplicate contexts, code blocks, URLs/contact strings, model identity boilerplate, certain role-play scripts, and noisy/time-sensitive Arabic completion tasks. All accepted examples fit at most 512 tokens with the Qwen3 tokenizer; complete answers are never truncated. This filter is heuristic, not exhaustive content or fact verification.

All turns of a source conversation share a split. The two languages of each authored scenario also stay together. Cross-split group IDs and exact first prompts are checked. This does not guarantee semantic near-duplicate removal across unrelated sources.

`conversation_sources.jsonl` contains only selected examples and supports offline rebuilding with a shorter token limit. `prepare_conversations.py` can reproduce source selection from the pinned parquet files. No private app conversation logs are included.

## Quality limits and evaluation

Rows were filtered and spot-checked, not exhaustively reviewed by Arabic language experts. Public annotations can still contain wrong facts or awkward wording. The Egyptian examples are a small synthetic adaptation set; native-speaker review and additional consented, corrected conversations are needed before customer deployment.

Keep the dev/test sets separate from training. Compare the untouched base and the adapter on identical held-out requests. JSON validity measures protocol compliance, not conversation quality. Score correctness, relevance, language/dialect, context retention, and naturalness separately. No model-quality benchmark improvement is claimed.

Preserve this attribution and the Apache license when redistributing the selected public data. Original project-authored examples are supplied as editable teaching material.
