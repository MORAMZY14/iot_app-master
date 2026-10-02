#!/usr/bin/env python3
"""Build split-by-conversation data and reject long examples without truncation.
The bundled source cache supports offline rebuilding at a shorter sequence length.
"""
import argparse,hashlib,json,random,re
from collections import Counter
from pathlib import Path
from conversation_data import SYSTEM,curated,pair,dumps
from training_utils import render_example,check_disjoint,file_hash
from validate_dataset import validate_record,validate
DATA=Path(__file__).parent/'dataset'
EXCLUDE=re.compile(r'https?://|www\.|[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}|```|<\|im_|<think>|'
 r'\b(ChatGPT|OpenAI|Claude|as an AI language model|stock price|diagnos\w*|dosage|credit card|password|API key|turn on|turn off|switch on|switch off)\b',re.I)
def normalized(s):return re.sub(r'\W+',' ',s.casefold()).strip()
def partition(s):
 n=int(hashlib.sha256(normalized(s).encode()).hexdigest()[:8],16)%10
 return 'test' if n==0 else 'dev' if n==1 else 'train'
def read(path):return [json.loads(s) for s in path.read_text(encoding='utf-8-sig').splitlines() if s.strip()]
def candidates(smol,aya):
 import pyarrow.parquet as pq
 yield from curated()
 for i,r in enumerate(read(DATA/'smarthome_train.jsonl')):
  r['messages'][0]['content']=SYSTEM
  yield dict(r,id=f'legacy-{i}',group_id=f'legacy-{i}',source='project-legacy',language=json.loads(r['messages'][1]['content'])['language'],split='train')
 for batch in pq.ParquetFile(aya).iter_batches(batch_size=2048,columns=['inputs','targets','annotation_type','language_code']):
  for x in batch.to_pylist():
   if x['language_code']!='arb' or x['annotation_type']!='original-annotations':continue
   user,reply=x['inputs'].strip(),x['targets'].strip()
   if not user or not reply or len(user)>600 or len(reply)>1200 or EXCLUDE.search(user+'\n'+reply):continue
   if not re.search(r'اشرح|فسر|كيف|لماذا|ما الفرق|قارن|اكتب|اقترح|ساعدني|لخص|ترجم|ما هو|ما هي|ماهي|ماهو',user):continue
   if re.search(r'أكمل|اكمل|كمل|استمرار|تابع الفقرة|قحبة|نوع من الأسئلة|ينتمي السؤال|أي صنف|أقوى|صح أم خطأ|صحيحة فإني|سياس|مظاهرات|انتخاب|التدخين|التبغ|أغنية|اغنية|كلمات أغاني|رقم الهاتف|كلمة السر|تشخيص|جرعة|الرئيس الحالي',user+' '+reply):continue
   digest=hashlib.sha256(dumps({'input':user,'target':reply}).encode()).hexdigest()
   group='aya-'+hashlib.sha256(normalized(user).encode()).hexdigest()[:24]
   yield dict(id=group,group_id=group,source='CohereLabs/aya_dataset:arb:original',source_sha256=digest,
      language='Arabic',split=partition(user),messages=[{'role':'system','content':SYSTEM}]+pair(user,reply,'Arabic'))
 for batch in pq.ParquetFile(smol).iter_batches(batch_size=2048,columns=['messages','source']):
  for x in batch.to_pylist():
   if x['source']!='smol-magpie-ultra-short':continue
   m=x['messages'];text='\n'.join(v['content'] for v in m)
   if EXCLUDE.search(text) or re.search(r'(?im)^(you are |act as |pretend (you|to))|save the tears|shut up|you idiot',text):continue
   if len(m)<2 or len(m)%2 or any(v['role']!=('user' if i%2==0 else 'assistant') for i,v in enumerate(m)):continue
   group='smol-'+hashlib.sha256(normalized(m[0]['content']).encode()).hexdigest()[:24]
   digest=hashlib.sha256(dumps(m).encode()).hexdigest();history=[{'role':'system','content':SYSTEM}]
   for i in range(0,len(m),2):
    user,reply=m[i]['content'].strip(),m[i+1]['content'].strip()
    if not user or not reply or len(user)>600 or len(reply)>1200:break
    history+=pair(user,reply,'English')
    yield dict(id=f'{group}-{i//2}',group_id=group,source='HuggingFaceTB/smol-smoltalk:smol-magpie-ultra-short',
      source_sha256=digest,language='English',split=partition(m[0]['content']),messages=list(history))

def build(tokenizer,rows,output,max_length=512,public_limit=800):
 splits={s:[] for s in ('train','dev','test')};seen=set();counts=Counter();rejected=Counter();lengths=[];cache=[]
 for r in rows:
  split=r['split'];external=r['source'].startswith(('CohereLabs/','HuggingFaceTB/'));bucket=(r['source'],split)
  limit=public_limit if split=='train' else max(50,public_limit//8)
  if external and counts[bucket]>=limit:continue
  validate_record(r);key=dumps(r['messages'][:-1]).casefold()
  if key in seen:rejected['duplicate_context']+=1;continue
  rendered=render_example(tokenizer,r['messages'])
  n=len(tokenizer(rendered['prompt']+rendered['completion'],add_special_tokens=False)['input_ids'])
  if n>max_length:rejected['too_long']+=1;continue
  seen.add(key);counts[bucket]+=1;lengths.append(n);splits[split].append(r);cache.append(r)
  # Sources are ordered curated -> Aya -> Smol. Stop after the last source fills.
  if r['source'].startswith('HuggingFaceTB/') and all(counts[(r['source'],s)]>=(public_limit if s=='train' else max(50,public_limit//8)) for s in splits):break
 for a,b in [('train','dev'),('train','test'),('dev','test')]:check_disjoint(splits[a],splits[b])
 if not all(splits.values()):raise ValueError('At least one split is empty. Increase max-length.')
 output.mkdir(parents=True,exist_ok=True);stats={}
 for split,rs in splits.items():
  random.Random(42).shuffle(rs);out=output/f'conversation_{split}.jsonl';out.write_text('\n'.join(map(dumps,rs))+'\n',encoding='utf-8');validate(out,1)
  stats[split]={'examples':len(rs),'conversations':len({r['group_id'] for r in rs}),'language':dict(Counter(r['language'] for r in rs)),
    'multi_turn_examples':sum(len(r['messages'])>3 for r in rs),'sources':dict(Counter(r['source'] for r in rs)),'sha256':file_hash(out)}
 manifest={'tokenizer':getattr(tokenizer,'name_or_path','unknown'),'max_length':max_length,'largest_example_tokens':max(lengths),
   'split_unit':'source conversation; both languages of each authored scenario stay together','splits':stats,'rejected':dict(rejected),
   'note':'Filtered and spot-checked teaching data, not a guarantee of factual or dialect accuracy. No private app chat logs. No trained weights included.'}
 (output/'dataset_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 return cache,manifest

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--tokenizer',default='Qwen/Qwen3-1.7B');p.add_argument('--offline',action='store_true')
 p.add_argument('--max-length',type=int,default=512);p.add_argument('--output',type=Path,default=DATA);p.add_argument('--public-limit',type=int,default=800)
 p.add_argument('--smol-parquet',type=Path);p.add_argument('--aya-parquet',type=Path);a=p.parse_args()
 if a.max_length<128 or a.public_limit<0:p.error('max-length >=128 and public-limit >=0 required')
 if bool(a.smol_parquet)!=bool(a.aya_parquet):p.error('Pass both parquet files or neither')
 from transformers import AutoTokenizer
 tokenizer=AutoTokenizer.from_pretrained(a.tokenizer,local_files_only=a.offline)
 rows=candidates(a.smol_parquet,a.aya_parquet) if a.smol_parquet else read(DATA/'conversation_sources.jsonl')
 cache,manifest=build(tokenizer,rows,a.output,a.max_length,a.public_limit)
 if a.smol_parquet:(a.output/'conversation_sources.jsonl').write_text('\n'.join(map(dumps,cache))+'\n',encoding='utf-8')
 print(json.dumps(manifest,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
