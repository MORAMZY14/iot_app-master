#!/usr/bin/env python3
"""Bundle a converted LiteRT model and Gemma tokenizer into one `.task`."""

from __future__ import annotations

import argparse
from pathlib import Path



def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tflite_model", type=Path)
    parser.add_argument("tokenizer_model", type=Path)
    parser.add_argument("output_task", type=Path)
    args = parser.parse_args()

    tflite_model = args.tflite_model.resolve()
    tokenizer_model = args.tokenizer_model.resolve()
    output_task = args.output_task.resolve()
    if not tflite_model.is_file():
        raise SystemExit(f"LiteRT model not found: {tflite_model}")
    if not tokenizer_model.is_file():
        raise SystemExit(f"Tokenizer not found: {tokenizer_model}")
    output_task.parent.mkdir(parents=True, exist_ok=True)

    if output_task.suffix.lower() != '.task':
        raise SystemExit('Output filename must end in .task')
    if output_task.exists():
        raise SystemExit('Output already exists. Choose a new .task filename.')
    with tflite_model.open('rb') as stream:
        header = stream.read(8)
    if len(header) < 8 or header[4:8] != b'TFL3':
        raise SystemExit('Input is not a TFLite FlatBuffer (TFL3 header missing).')
    try:
        from mediapipe.tasks.python.genai import bundler
    except ImportError as error:
        raise SystemExit('This MediaPipe installation has no GenAI bundler. Use a fresh Python 3.11 '
                         'environment and: python -m pip install -r training/requirements-bundle.txt') from error
    temporary_task = output_task.with_name(output_task.stem + '.partial.task')
    config = bundler.BundleConfig(
        tflite_model=str(tflite_model),
        tokenizer_model=str(tokenizer_model),
        start_token="<bos>",
        stop_tokens=["<eos>", "<end_of_turn>"],
        output_filename=str(temporary_task),
        prompt_prefix="<start_of_turn>user\n",
        prompt_suffix="<end_of_turn>\n<start_of_turn>model\n",
    )
    try:
        bundler.create_bundle(config)
        temporary_task.replace(output_task)
    finally:
        temporary_task.unlink(missing_ok=True)
    from training_utils import file_hash
    print(f'SHA256: {file_hash(output_task)}')
    print(f"Mobile model created: {output_task}")


if __name__ == "__main__":
    main()
