"""Local-only Transformers inference. Never contacts the ESP32."""
import json,re
from pathlib import Path
from training_utils import chat_options

def load_model(path,cpu=False):
 import torch
 from transformers import AutoModelForCausalLM,AutoTokenizer,BitsAndBytesConfig
 from peft import PeftConfig,PeftModel
 source=Path(path).resolve()
 if not source.exists():raise ValueError(f'Missing local model folder: {source}. Run download_base_model.py first.')
 adapter=(source/'adapter_config.json').is_file()
 base=PeftConfig.from_pretrained(str(source),local_files_only=True).base_model_name_or_path if adapter else str(source)
 cuda=torch.cuda.is_available() and not cpu
 options={'device_map':{'':0 if cuda else 'cpu'},'torch_dtype':torch.float16 if cuda else torch.float32,
   'local_files_only':True,'attn_implementation':'eager'}
 if cuda:options['quantization_config']=BitsAndBytesConfig(load_in_4bit=True,bnb_4bit_quant_type='nf4',bnb_4bit_use_double_quant=True,bnb_4bit_compute_dtype=torch.float16)
 model=AutoModelForCausalLM.from_pretrained(base,**options)
 if adapter:model=PeftModel.from_pretrained(model,str(source),local_files_only=True)
 tokenizer=AutoTokenizer.from_pretrained(str(source) if (source/'tokenizer_config.json').exists() else base,local_files_only=True)
 model.eval();return model,tokenizer

def bounded_prompt(tokenizer,messages):
 result=list(messages)
 while True:
  prompt=tokenizer.apply_chat_template(result,tokenize=False,add_generation_prompt=True,**chat_options(tokenizer))
  if len(tokenizer(prompt,add_special_tokens=False)['input_ids'])+384<=2048:return prompt
  if len(result)<=2:raise ValueError('Please shorten your message or saved preferences.')
  result=result[:1]+result[3:]

def generate(model,tokenizer,messages,seed=42):
 import torch
 inputs=tokenizer(bounded_prompt(tokenizer,messages),return_tensors='pt',add_special_tokens=False).to(model.device)
 eos=[tokenizer.eos_token_id]
 if 'gemma' in tokenizer.__class__.__name__.lower():
  token=tokenizer.convert_tokens_to_ids('<end_of_turn>')
  if token is not None and token!=tokenizer.unk_token_id:eos.append(token)
 torch.manual_seed(seed)
 with torch.inference_mode():
  output=model.generate(**inputs,max_new_tokens=384,do_sample=True,temperature=0.7,top_p=0.8,top_k=20,
     repetition_penalty=1.05,pad_token_id=tokenizer.eos_token_id,eos_token_id=list(set(eos)))
 return tokenizer.decode(output[0,inputs['input_ids'].shape[1]:],skip_special_tokens=True).strip()

def parse_envelope(raw):
 value=json.loads(re.sub(r'<think>[\s\S]*?</think>','',raw).strip())
 if not isinstance(value,dict) or set(value)!={'reply','device_command'}:raise ValueError('Expected reply and device_command')
 if not isinstance(value['reply'],str) or not value['reply'].strip():raise ValueError('Missing reply')
 if value['device_command'] is not None and (not isinstance(value['device_command'],str) or not value['device_command'].strip()):raise ValueError('Invalid command type')
 return value
