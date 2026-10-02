#!/usr/bin/env python3
"""Fine-tune Gemma 3 1B for this app's bilingual JSON command protocol."""

from __future__ import annotations

import argparse
import gc
import json
from pathlib import Path

from training_utils import file_hash, render_example, resolve_checkpoint, save_tokenizer_assets, check_disjoint
from validate_dataset import validate


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-model", default="google/gemma-3-1b-it")
    parser.add_argument(
        "--dataset",
        type=Path,
        default=Path(__file__).parent / "dataset" / "smarthome_train.jsonl",
    )
    parser.add_argument("--output-dir", type=Path, default=Path("outputs/smarthome-gemma3-1b"))
    parser.add_argument("--epochs", type=float, default=3.0)
    parser.add_argument("--learning-rate", type=float, default=2e-4)
    parser.add_argument("--max-length", type=int)
    parser.add_argument("--profile", choices=("standard", "gtx1650"), default="standard")
    parser.add_argument("--lora-rank", type=int)
    parser.add_argument("--save-steps", type=int, default=10)
    parser.add_argument("--max-steps", type=int, default=-1)
    parser.add_argument("--resume-from-checkpoint", nargs="?", const="latest")
    parser.add_argument("--eval-dataset", type=Path)
    parser.add_argument("--gradient-accumulation", type=int, default=8)
    parser.add_argument(
        "--no-4bit",
        action="store_true",
        help="Use regular LoRA. This can run without bitsandbytes but needs much more RAM/VRAM.",
    )
    parser.add_argument("--skip-merge", action="store_true")
    args = parser.parse_args(argv)
    if args.max_length is None:
        args.max_length = 384 if args.profile == 'gtx1650' else 768
    if args.lora_rank is None:
        args.lora_rank = 8 if args.profile == 'gtx1650' else 16
    for key in ('max_length', 'lora_rank', 'gradient_accumulation', 'save_steps', 'epochs', 'learning_rate'):
        if getattr(args, key) <= 0:
            parser.error(f'--{key.replace("_", "-")} must be positive')
    if args.max_steps == 0 or args.max_steps < -1:
        parser.error('--max-steps must be -1 or a positive integer')
    return args


def main() -> None:
    args = parse_args()
    dataset_path = args.dataset.resolve()
    output_dir = args.output_dir.resolve()
    adapter_dir = output_dir / "adapter"
    merged_dir = output_dir / "merged"
    validate(dataset_path)
    try:
        checkpoint = resolve_checkpoint(args.resume_from_checkpoint, output_dir)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    if checkpoint is None and output_dir.exists() and any(output_dir.iterdir()):
        raise SystemExit('Output folder is not empty. Use --resume-from-checkpoint latest or a NEW --output-dir.')
    import torch
    from datasets import load_dataset
    from peft import LoraConfig, prepare_model_for_kbit_training
    from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig, set_seed
    from trl import SFTConfig, SFTTrainer
    set_seed(42)
    manifest_path = output_dir / 'training_manifest.json'
    manifest = {'base_model': args.base_model, 'dataset_sha256': file_hash(dataset_path),
                'max_length': args.max_length, 'gradient_accumulation': args.gradient_accumulation,
                'profile': args.profile, 'completion_only_loss': checkpoint is None}
    if checkpoint and manifest_path.is_file():
        previous = json.loads(manifest_path.read_text(encoding='utf-8'))
        for key in ('base_model', 'dataset_sha256', 'max_length', 'gradient_accumulation'):
            if key in previous and previous[key] != manifest[key]:
                raise SystemExit(f'Resume setting differs: {key}. Reuse the original data and settings.')
        manifest['completion_only_loss'] = previous.get('completion_only_loss', False)
    elif checkpoint:
        manifest['completion_only_loss'] = False
        print('Legacy checkpoint: reuse its original epochs, max length, accumulation and data.')

    use_4bit = not args.no_4bit
    if use_4bit and not torch.cuda.is_available():
        raise SystemExit(
            "4-bit QLoRA needs an NVIDIA CUDA GPU. Use Linux/WSL with CUDA, or pass "
            "--no-4bit for a much slower, higher-memory regular LoRA run."
        )

    tokenizer = AutoTokenizer.from_pretrained(args.base_model)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token

    if torch.cuda.is_available():
        compute_dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
        device_map = {"": 0}
    elif torch.backends.mps.is_available():
        compute_dtype = torch.float16
        device_map = {"": "mps"}
    else:
        compute_dtype = torch.float32
        device_map = {"": "cpu"}

    model_kwargs: dict[str, object] = {
        "device_map": device_map,
        "torch_dtype": compute_dtype,
        "attn_implementation": "eager",
    }
    if use_4bit:
        model_kwargs["quantization_config"] = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_use_double_quant=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_compute_dtype=compute_dtype,
        )

    model = AutoModelForCausalLM.from_pretrained(args.base_model, **model_kwargs)
    model.config.use_cache = False
    if use_4bit:
        model = prepare_model_for_kbit_training(model, gradient_checkpointing_kwargs={"use_reentrant": False})

    raw_dataset = load_dataset("json", data_files=str(dataset_path), split="train")

    def render(example):
        result = render_example(tokenizer, example['messages'])
        length = len(tokenizer(result['prompt'] + result['completion'], add_special_tokens=False)['input_ids'])
        if length > args.max_length:
            raise ValueError(f'Example has {length} tokens, exceeding --max-length={args.max_length}. '
                             'Increase the limit or shorten the example; do not silently truncate answers.')
        return result if manifest['completion_only_loss'] else {'text': result['prompt'] + result['completion']}

    dataset = raw_dataset.map(render, remove_columns=raw_dataset.column_names)
    eval_dataset = None
    if args.eval_dataset:
        validate(args.eval_dataset, minimum_examples=1)
        evaluation = load_dataset('json', data_files=str(args.eval_dataset), split='train')
        check_disjoint(raw_dataset, evaluation)
        eval_dataset = evaluation.map(render, remove_columns=evaluation.column_names)
    peft_config = LoraConfig(
        r=args.lora_rank,
        lora_alpha=args.lora_rank * 2,
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=["q_proj", "v_proj"] if args.profile == "gtx1650" else [
            "q_proj",
            "k_proj",
            "v_proj",
            "o_proj",
            "gate_proj",
            "up_proj",
            "down_proj",
        ],
    )
    if checkpoint:
        peft_config = LoraConfig.from_pretrained(str(checkpoint))
        if peft_config.base_model_name_or_path != args.base_model:
            raise SystemExit('Checkpoint base model differs. Pass its original --base-model.')
    output_dir.mkdir(parents=True, exist_ok=True)
    training_config = SFTConfig(
        output_dir=str(output_dir / "checkpoints"),
        dataset_text_field="text",
        max_length=args.max_length,
        num_train_epochs=args.epochs,
        max_steps=args.max_steps,
        per_device_eval_batch_size=1,
        per_device_train_batch_size=1,
        gradient_accumulation_steps=args.gradient_accumulation,
        learning_rate=args.learning_rate,
        logging_steps=1,
        save_strategy="steps",
        save_steps=args.save_steps,
        save_total_limit=3,
        eval_strategy="epoch" if eval_dataset is not None else "no",
        completion_only_loss=manifest['completion_only_loss'],
        optim="paged_adamw_8bit" if use_4bit else "adamw_torch",
        dataloader_num_workers=0,
        dataloader_pin_memory=False,
        report_to="none",
        fp16=compute_dtype == torch.float16 and torch.cuda.is_available(),
        bf16=compute_dtype == torch.bfloat16,
        gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False},
        packing=False,
        seed=42,
    )
    trainer = SFTTrainer(
        model=model,
        args=training_config,
        train_dataset=dataset,
        eval_dataset=eval_dataset,
        peft_config=peft_config,
        processing_class=tokenizer,
    )
    manifest.update({'examples': len(dataset), 'epochs': args.epochs, 'adapter': str(adapter_dir)})
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    try:
        trainer.train(resume_from_checkpoint=str(checkpoint) if checkpoint else None)
    except torch.cuda.OutOfMemoryError:
        raise SystemExit('GPU memory exhausted. Close GPU apps and start a separate --profile gtx1650 run. '
                         'Do not change sequence length mid-resume.')
    trainer.save_model(str(adapter_dir))
    trainer.save_state()
    save_tokenizer_assets(tokenizer, adapter_dir, args.base_model)
    print(f"Adapter saved to {adapter_dir}")
    if args.skip_merge:
        return

    # Mobile conversion needs one merged Hugging Face model directory rather
    # than a base model plus a separate adapter.
    del trainer
    del model
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    from merge_adapter import merge
    merge(adapter_dir, merged_dir)


if __name__ == "__main__":
    main()
