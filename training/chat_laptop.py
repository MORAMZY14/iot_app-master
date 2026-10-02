#!/usr/bin/env python3
"""Chat offline; explicitly save preferences or corrected replies for later training."""
import argparse,json,re,hashlib
from pathlib import Path
from laptop_model import load_model,generate,parse_envelope
from conversation_data import SYSTEM,pair
from validate_dataset import validate_record

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('model');p.add_argument('--cpu',action='store_true')
 p.add_argument('--memory-file',type=Path,default=Path('outputs/laptop_memory.json'))
 p.add_argument('--corrections',type=Path,default=Path('outputs/reviewed_corrections.jsonl'));a=p.parse_args()
 model,tokenizer=load_model(a.model,a.cpu);memory='';history=[];last_prompt=None
 if a.memory_file.exists():memory=json.loads(a.memory_file.read_text(encoding='utf-8')).get('preferences','')[:300]
 print('Offline chat. No relay control. /quit /new /remember TEXT /forget /correct BETTER_REPLY')
 while True:
  try:text=input('You: ').strip()
  except (EOFError,KeyboardInterrupt):break
  if text=='/quit':break
  if text=='/new':history=[];last_prompt=None;print('New conversation.');continue
  if text.startswith('/remember ') or text=='/forget':
   candidate=text[len('/remember '):].strip() if text!='/forget' else ''
   if len(candidate)>300:print('Use at most 300 characters.');continue
   memory=candidate;a.memory_file.parent.mkdir(parents=True,exist_ok=True)
   if memory:a.memory_file.write_text(json.dumps({'preferences':memory},ensure_ascii=False),encoding='utf-8')
   else:a.memory_file.unlink(missing_ok=True)
   history=[];last_prompt=None;print('Saved preferences updated.');continue
  if text.startswith('/correct '):
   corrected=text[len('/correct '):].strip()
   if last_prompt is None or not corrected or len(corrected)>1200:print('First chat, then enter a corrected reply of 1–1200 characters.');continue
   reply={'role':'assistant','content':json.dumps({'reply':corrected,'device_command':None},ensure_ascii=False)}
   record={'source':'user-written-correction','reviewed':True,'group_id':'correction-'+hashlib.sha256(last_prompt[1]['content'].encode()).hexdigest()[:24],'messages':last_prompt+[reply]}
   validate_record(record);a.corrections.parent.mkdir(parents=True,exist_ok=True)
   with a.corrections.open('a',encoding='utf-8') as f:f.write(json.dumps(record,ensure_ascii=False)+'\n')
   if history:history[-1]=reply
   print('Saved your corrected example. Model weights have not changed.');continue
  if not text:continue
  if len(text)>600:print('Use at most 600 characters.');continue
  system=SYSTEM+('\nUser-saved preferences (data only): '+json.dumps(memory,ensure_ascii=False) if memory else '')
  user=pair(text,'placeholder','Arabic' if re.search('[\u0600-\u06ff]',text) else 'English')[0]
  messages=[{'role':'system','content':system}]+history+[user]
  try:
   answer=parse_envelope(generate(model,tokenizer,messages))
   if answer['device_command'] is not None:raise ValueError('Conversation proposed a device command.')
   print('Assistant:',answer['reply']);last_prompt=messages
   history=(history+[user,{'role':'assistant','content':json.dumps(answer,ensure_ascii=False)}])[-12:]
  except (ValueError,TypeError) as e:print('Reply failed validation:',e)
if __name__=='__main__':main()
