import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from train_gemma3_lora import parse_args
from training_utils import resolve_checkpoint, render_example
from validate_dataset import validate
from laptop_model import parse_envelope

class TrainingToolsTests(unittest.TestCase):
    def test_low_memory_profile_and_override(self):
        self.assertEqual(parse_args(['--profile','gtx1650']).max_length,384)
        self.assertEqual(parse_args(['--profile','gtx1650','--max-length','512']).max_length,512)
        self.assertEqual(parse_args(['--profile','gtx1650']).lora_rank,8)

    def test_latest_skips_incomplete_checkpoints(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for number in (5,10,20):
                folder=root/'checkpoints'/f'checkpoint-{number}'
                folder.mkdir(parents=True)
                for file in ('trainer_state.json','adapter_config.json','adapter_model.safetensors','optimizer.pt','scheduler.pt'):
                    if number != 20 or file != 'optimizer.pt':
                        (folder/file).write_text('{}')
            self.assertEqual(resolve_checkpoint('latest',root).name,'checkpoint-10')
            with self.assertRaises(ValueError):
                resolve_checkpoint(str(root/'checkpoints/checkpoint-20'),root)

    def test_missing_checkpoint_fails_explicitly(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError): resolve_checkpoint('latest',Path(directory))

    def test_malformed_jsonl_has_useful_error(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'bad.jsonl'
            for content in ('[]','{"messages":[1,2,3]}'):
                file.write_text(content)
                with self.assertRaisesRegex(ValueError,'line 1'): validate(file)

    def test_train_and_eval_are_valid_and_disjoint(self):
        folder=Path(__file__).resolve().parents[1]/'dataset'
        train, evaluation=folder/'smarthome_train.jsonl',folder/'smarthome_eval.jsonl'
        self.assertEqual(validate(train),34)
        self.assertEqual(validate(evaluation),24)
        def prompts(file):
            return {json.loads(json.loads(line)['messages'][1]['content'])['user_text'].strip().casefold()
                for line in file.read_text(encoding='utf-8').splitlines() if line.strip()}
        self.assertFalse(prompts(train)&prompts(evaluation))

    def test_bom_from_windows_editor(self):
        source=Path(__file__).resolve().parents[1]/'dataset/smarthome_train.jsonl'
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)/'bom.jsonl'
            target.write_text(source.read_text(encoding='utf-8'),encoding='utf-8-sig')
            self.assertEqual(validate(target),34)

    def test_completion_mask_preserves_model_template(self):
        class Tokenizer:
            def apply_chat_template(self,messages,tokenize,add_generation_prompt):
                return 'prompt:' if add_generation_prompt else 'prompt:answer<eos>'
        self.assertEqual(render_example(Tokenizer(),[{}, {}, {}]),{'prompt':'prompt:','completion':'answer<eos>'})

    def test_output_schema_rejects_action_objects(self):
        self.assertEqual(parse_envelope('{"reply":"Hi","device_command":null}')['reply'],'Hi')
        for raw in ('TextResponse("hello")','{"reply":"OK","device_command":{"pin":1}}','{"reply":""}'):
            with self.assertRaises(ValueError): parse_envelope(raw)

if __name__=='__main__': unittest.main()
