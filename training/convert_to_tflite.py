#!/usr/bin/env python3
"""Convert a merged Gemma 3 Hugging Face directory to CPU LiteRT."""

from __future__ import annotations

import argparse
from pathlib import Path



def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("model_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--model-size", choices=("1b", "270m"), default="1b")
    parser.add_argument("--name", default="smarthome-gemma3")
    parser.add_argument("--prefill-seq-len", type=int, default=512)
    parser.add_argument("--kv-cache-max-len", type=int, default=2048)
    args = parser.parse_args()

    model_dir = args.model_dir.resolve()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    required = ("config.json", "tokenizer.model")
    missing = [name for name in required if not (model_dir / name).exists()]
    if missing:
        raise SystemExit(f"Missing from merged model directory: {', '.join(missing)}")

    if args.prefill_seq_len <= 0 or args.kv_cache_max_len < 1536 or args.prefill_seq_len > args.kv_cache_max_len:
        raise SystemExit('Use a positive prefill length <= cache length; this app requires cache length >= 1536.')
    if any(output_dir.iterdir()):
        raise SystemExit('Output folder is not empty. Choose a new folder to avoid mixing model exports.')
    print('Starting CPU conversion. A quiet terminal does not mean it is stuck.', flush=True)
    from litert_torch.generative.examples.gemma3 import gemma3
    from litert_torch.generative.layers import kv_cache
    from litert_torch.generative.utilities import converter
    from litert_torch.generative.utilities.export_config import ExportConfig

    pytorch_model = (
        gemma3.build_model_1b(str(model_dir))
        if args.model_size == "1b"
        else gemma3.build_model_270m(str(model_dir))
    )
    export_config = ExportConfig()
    export_config.kvcache_layout = kv_cache.KV_LAYOUT_TRANSPOSED
    export_config.mask_as_input = True
    converter.convert_to_tflite(
        pytorch_model,
        output_path=str(output_dir),
        output_name_prefix=args.name,
        prefill_seq_len=args.prefill_seq_len,
        kv_cache_max_len=args.kv_cache_max_len,
        quantize="dynamic_int8",
        export_config=export_config,
    )
    import json
    (output_dir / 'export_manifest.json').write_text(json.dumps({
        'model_dir': str(model_dir), 'model_size': args.model_size, 'prefill_seq_len': args.prefill_seq_len,
        'kv_cache_max_len': args.kv_cache_max_len, 'quantize': 'dynamic_int8', 'backend': 'cpu'
    }, indent=2) + '\n', encoding='utf-8')
    print(f"LiteRT export finished in {output_dir}")


if __name__ == "__main__":
    main()
