import copy,json,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from conversation_data import curated
from training_utils import check_disjoint,render_example
from validate_dataset import validate_record,validate
from prepare_conversations import partition
class ConversationTests(unittest.TestCase):
 def test_languages_and_followups_share_split(self):
  groups={}
  for r in curated():validate_record(r);groups.setdefault(r['group_id'],set()).add(r['split'])
  self.assertTrue(all(len(s)==1 for s in groups.values()))
 def test_command_in_historical_conversation_rejected(self):
  r=copy.deepcopy(curated()[1]);r['messages'][2]['content']=json.dumps({'reply':'Done','device_command':'turn on Lamp'})
  with self.assertRaisesRegex(ValueError,'cannot emit'):validate_record(r)
 def test_partial_pair_rejected(self):
  r=copy.deepcopy(curated()[0]);r['messages'].pop()
  with self.assertRaisesRegex(ValueError,'complete'):validate_record(r)
 def test_group_leak_rejected_even_with_different_prompts(self):
  a,b=copy.deepcopy(curated()[0]),copy.deepcopy(curated()[2]);b['group_id']=a['group_id']
  with self.assertRaisesRegex(ValueError,'overlap'):check_disjoint([a],[b])
 def test_non_thinking_template_in_prompt_and_target(self):
  class Tokenizer:
   chat_template='enable_thinking'
   def apply_chat_template(self,messages,tokenize,add_generation_prompt,enable_thinking):
    assert enable_thinking is False
    return 'prefix<think></think>'+('' if add_generation_prompt else '{"reply":"Hi","device_command":null}<eos>')
  self.assertTrue(render_example(Tokenizer(),curated()[0]['messages'])['completion'].startswith('{'))
 def test_split_normalizes_punctuation_and_case(self):
  self.assertEqual(partition('HELLO, World!'),partition('hello world'))
 def test_dataset_files_disjoint(self):
  root=Path(__file__).resolve().parents[1]/'dataset'
  splits={s:[json.loads(l) for l in (root/f'conversation_{s}.jsonl').read_text(encoding='utf-8').splitlines()] for s in ('train','dev','test')}
  for s,rows in splits.items():
   self.assertEqual(validate(root/f'conversation_{s}.jsonl',1),len(rows))
   self.assertTrue(any(len(r['messages'])>3 for r in rows))
  for a,b in [('train','dev'),('train','test'),('dev','test')]:check_disjoint(splits[a],splits[b])
if __name__=='__main__':unittest.main()
