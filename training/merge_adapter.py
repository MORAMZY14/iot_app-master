#!/usr/bin/env python3
"""Merge an existing adapter or checkpoint on CPU without retraining."""
import argparse
from pathlib import Path
from training_utils import save_tokenizer_assets


def merge(adapter, output):
    if not (adapter / 'adapter_config.json').is_file():
        raise SystemExit(f'No adapter_config.json in {adapter}')
    if output.exists() and any(output.iterdir()):
        raise SystemExit(f'Output is not empty: {output}. Choose a new merge folder.')
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from peft import PeftConfig, PeftModel
    config = PeftConfig.from_pretrained(str(adapter))
    base_name = config.base_model_name_or_path
    print('Merging on CPU; keep several GB of RAM available.', flush=True)
    base = AutoModelForCausalLM.from_pretrained(base_name, device_map={'': 'cpu'},
                                              torch_dtype=torch.float32, low_cpu_mem_usage=True)
    model = PeftModel.from_pretrained(base, str(adapter)).merge_and_unload(safe_merge=True)
    output.mkdir(parents=True, exist_ok=True)
    model.to(torch.float16).save_pretrained(str(output), safe_serialization=True, max_shard_size='2GB')
    tokenizer = AutoTokenizer.from_pretrained(str(adapter) if (adapter / 'tokenizer_config.json').exists() else base_name)
    save_tokenizer_assets(tokenizer, output, base_name)
    print(f'Merged model and original tokenizer: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('adapter', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    merge(args.adapter.resolve(), args.output.resolve())
