#!/usr/bin/env python3
"""One-time online download; the receipt pins the exact local snapshot."""
import argparse,json
from pathlib import Path
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--model',default='Qwen/Qwen3-1.7B');p.add_argument('--revision',default='main')
 p.add_argument('--receipt',type=Path,default=Path('outputs/model_download.json'));a=p.parse_args()
 from huggingface_hub import HfApi,snapshot_download
 sha=HfApi().model_info(a.model,revision=a.revision).sha
 local=snapshot_download(a.model,revision=sha,allow_patterns=['*.json','*.safetensors','tokenizer.model','*.txt','*.jinja','LICENSE*','README.md'])
 a.receipt.parent.mkdir(parents=True,exist_ok=True);a.receipt.write_text(json.dumps({'model':a.model,'revision':sha,'snapshot':local},indent=2)+'\n',encoding='utf-8')
 print(f'Model saved locally: {local}\nReceipt: {a.receipt}')
