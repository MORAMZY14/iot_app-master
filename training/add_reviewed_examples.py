#!/usr/bin/env python3
"""Merge approved conversational corrections, protecting held-out conversations."""
import argparse,json
from pathlib import Path
from training_utils import check_disjoint
from validate_dataset import validate,validate_record

def read(p):return [json.loads(s) for s in p.read_text(encoding='utf-8-sig').splitlines() if s.strip()]
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--corrections',required=True,type=Path);p.add_argument('--output',required=True,type=Path)
 p.add_argument('--training',type=Path,default=Path(__file__).parent/'dataset/conversation_train.jsonl');p.add_argument('--holdout',action='append',type=Path);a=p.parse_args()
 if a.output.exists():p.error('Choose a new output file.')
 rows=read(a.training);new=read(a.corrections)
 for r in new:
  validate_record(r)
  if r.get('reviewed') is not True:p.error('Corrections must be marked reviewed=true.')
  if any(json.loads(m['content'])['device_command'] is not None for m in r['messages'] if m['role']=='assistant'):p.error('Conversational corrections only.')
 for h in (a.holdout or [Path(__file__).parent/'dataset/conversation_dev.jsonl',Path(__file__).parent/'dataset/conversation_test.jsonl']):check_disjoint(rows+new,read(h))
 unique={json.dumps(r['messages'][:-1],ensure_ascii=False,sort_keys=True).casefold():r for r in rows+new}
 a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text('\n'.join(json.dumps(r,ensure_ascii=False) for r in unique.values())+'\n',encoding='utf-8');validate(a.output)
 print('Start a NEW training output folder for this changed dataset.')
