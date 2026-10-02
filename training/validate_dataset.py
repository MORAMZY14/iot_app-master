#!/usr/bin/env python3
"""Validate the app protocol on every turn, including historical turns."""
import argparse,json
from pathlib import Path

def validate_record(r):
 if not isinstance(r,dict):raise ValueError('record must be an object')
 m=r.get('messages')
 if not isinstance(m,list) or len(m)<3 or len(m)%2!=1:raise ValueError('need a system message and complete user/assistant pairs')
 for i,x in enumerate(m):
  role='system' if i==0 else 'user' if i%2 else 'assistant'
  if not isinstance(x,dict) or x.get('role')!=role:raise ValueError(f'message {i}: expected {role}')
  if not isinstance(x.get('content'),str) or not x['content'].strip():raise ValueError('content must be non-empty text')
 for i in range(1,len(m),2):
  u,a=json.loads(m[i]['content']),json.loads(m[i+1]['content'])
  if not isinstance(u,dict) or set(u)!={'language','allow_device_command','user_text'}:raise ValueError('invalid user envelope')
  if u['language'] not in ('English','Arabic') or not isinstance(u['allow_device_command'],bool):raise ValueError('invalid language or command flag')
  if not isinstance(u['user_text'],str) or not u['user_text'].strip():raise ValueError('user_text must be non-empty')
  if not isinstance(a,dict) or set(a)!={'reply','device_command'}:raise ValueError('invalid assistant envelope')
  if not isinstance(a['reply'],str) or not a['reply'].strip():raise ValueError('reply must be non-empty')
  if a['device_command'] is not None and (not isinstance(a['device_command'],str) or not a['device_command'].strip()):raise ValueError('invalid command')
  if not u['allow_device_command'] and a['device_command'] is not None:raise ValueError('conversation cannot emit a command')
 return m

def validate(path,minimum_examples=20):
 seen=set();count=0
 for n,line in enumerate(Path(path).read_text(encoding='utf-8-sig').splitlines(),1):
  if not line.strip():continue
  try:
   m=validate_record(json.loads(line));key=json.dumps(m[:-1],sort_keys=True,ensure_ascii=False).casefold()
   if key in seen:raise ValueError('duplicate conversation context')
   seen.add(key);count+=1
  except (ValueError,TypeError) as e:raise ValueError(f'line {n}: {e}') from e
 if count<minimum_examples:raise ValueError(f'only {count} examples, need {minimum_examples}')
 print(f'OK: {count} valid conversations in {path}');return count
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('dataset',nargs='?',type=Path,default=Path(__file__).parent/'dataset/smarthome_train.jsonl');validate(p.parse_args().dataset)
