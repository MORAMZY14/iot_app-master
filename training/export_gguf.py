#!/usr/bin/env python3
"""Convert a merged Hugging Face model using an existing llama.cpp checkout."""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--model',required=True,type=Path);p.add_argument('--llama-cpp',required=True,type=Path)
 p.add_argument('--output',type=Path,default=Path('outputs/smarthome-qwen3-1.7b-Q4_K_M.gguf'));a=p.parse_args()
 model=a.model.resolve();root=a.llama_cpp.resolve();out=a.output.resolve()
 if not (model/'config.json').exists() or (model/'adapter_config.json').exists():p.error('Merge the adapter first; use the full model folder.')
 if out.exists():p.error('Choose a new output filename.')
 converter=root/'convert_hf_to_gguf.py'
 quantizer=next((x for x in [root/'build/bin/llama-quantize',root/'build/bin/Release/llama-quantize.exe',root/'build/bin/llama-quantize.exe'] if x.exists()),None)
 if not converter.exists() or quantizer is None:p.error('Build llama.cpp first; see LAPTOP_TRAINING.md.')
 intermediate=out.with_name(out.stem+'-f16.gguf')
 if intermediate.exists():p.error('Move the existing intermediate file aside or use a new output name.')
 out.parent.mkdir(parents=True,exist_ok=True)
 subprocess.run([sys.executable,str(converter),str(model),'--outfile',str(intermediate),'--outtype','f16'],check=True)
 subprocess.run([str(quantizer),str(intermediate),str(out),'Q4_K_M'],check=True)
 digest=hashlib.sha256()
 with out.open('rb') as f:
  if f.read(4)!=b'GGUF':raise ValueError('Missing GGUF header')
  f.seek(0)
  for chunk in iter(lambda:f.read(1024*1024),b''):digest.update(chunk)
 revision=subprocess.run(['git','-C',str(root),'rev-parse','HEAD'],capture_output=True,text=True,check=True).stdout.strip()
 out.with_suffix('.manifest.json').write_text(json.dumps({'model':str(model),'quantization':'Q4_K_M','llama_cpp_revision':revision,'bytes':out.stat().st_size,'sha256':digest.hexdigest()},indent=2)+'\n')
 print(f'GGUF ready: {out}\nKeep the f16 intermediate until you have tested the GGUF.')
