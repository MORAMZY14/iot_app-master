"""Dependency-free checks shared by training, evaluation and export."""
import hashlib
from pathlib import Path


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def checkpoint_complete(path):
    return all((path / name).is_file() for name in (
        'trainer_state.json', 'adapter_config.json', 'optimizer.pt', 'scheduler.pt')) and any(
        (path / name).is_file() for name in ('adapter_model.safetensors', 'adapter_model.bin'))


def resolve_checkpoint(value, output_dir):
    if value is None:
        return None
    if value == 'latest':
        candidates = [p for p in (output_dir / 'checkpoints').glob('checkpoint-*')
                      if p.is_dir() and p.name.split('-')[-1].isdigit() and checkpoint_complete(p)]
        if not candidates:
            raise ValueError('No complete checkpoint found. Start without --resume-from-checkpoint.')
        return max(candidates, key=lambda p: int(p.name.split('-')[-1])).resolve()
    checkpoint = Path(value).resolve()
    if not checkpoint_complete(checkpoint):
        raise ValueError(f'Incomplete checkpoint: {checkpoint}. Expected trainer_state.json, '
                         'adapter config/weights, optimizer.pt and scheduler.pt. '
                         'Adapter-only folders can be merged but cannot exactly resume training.')
    return checkpoint


def render_example(tokenizer, messages):
    prompt = tokenizer.apply_chat_template(messages[:-1], tokenize=False, add_generation_prompt=True, **chat_options(tokenizer))
    full = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=False, **chat_options(tokenizer))
    if not full.startswith(prompt):
        raise ValueError('Tokenizer template does not produce a matching prompt prefix.')
    return {'prompt': prompt, 'completion': full[len(prompt):]}


def save_tokenizer_assets(tokenizer, destination, base_model):
    tokenizer.save_pretrained(str(destination))
    if "gemma" not in str(base_model).lower(): return
    target = destination / 'tokenizer.model'
    if target.is_file():
        return
    # Fast tokenizers may omit the SentencePiece asset MediaPipe requires.
    import shutil
    source = Path(base_model) / 'tokenizer.model'
    if not source.is_file():
        from huggingface_hub import hf_hub_download
        source = Path(hf_hub_download(base_model, 'tokenizer.model'))
    shutil.copyfile(source, target)


def chat_options(tokenizer):
    return {'enable_thinking':False} if 'enable_thinking' in (getattr(tokenizer,'chat_template','') or '') else {}

def check_disjoint(train,evaluation):
    import json
    groups={r.get('group_id') for r in train if r.get('group_id')}
    prompts={json.loads(r['messages'][1]['content'])['user_text'].strip().casefold() for r in train}
    for r in evaluation:
        if r.get('group_id') in groups or json.loads(r['messages'][1]['content'])['user_text'].strip().casefold() in prompts:
            raise ValueError('Training/evaluation conversation overlap detected.')
