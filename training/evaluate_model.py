#!/usr/bin/env python3
"""Evaluate actual generations on held-out data; never send a proposed command."""
import argparse
import json
from pathlib import Path
from laptop_model import load_model, generate, parse_envelope
from validate_dataset import validate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model')
    parser.add_argument('--dataset', type=Path, default=Path(__file__).parent / 'dataset/conversation_test.jsonl')
    parser.add_argument('--report', type=Path, default=Path('outputs/evaluation.json'))
    parser.add_argument('--cpu', action='store_true')
    args = parser.parse_args()
    validate(args.dataset, minimum_examples=1)
    model, tokenizer = load_model(args.model, args.cpu)
    results = []
    for line in args.dataset.read_text(encoding='utf-8-sig').splitlines():
        if not line.strip():
            continue
        messages = json.loads(line)['messages']
        request = json.loads(messages[-2]['content'])
        expected = json.loads(messages[-1]['content'])
        raw = generate(model, tokenizer, messages[:-1])
        item = {'language':request['language'], 'turns':(len(messages)-1)//2, 'user_text':request['user_text'], 'raw':raw, 'valid_json':False, 'command_match':False}
        try:
            actual = parse_envelope(raw)
            item.update(valid_json=True, command_match=actual['device_command'] == expected['device_command'], reply=actual['reply'], expected_reply=expected['reply'], unexpected_action=actual['device_command'] is not None and expected['device_command'] is None)
        except (ValueError, TypeError):
            pass
        results.append(item)
        print(f'{len(results)}: JSON={item["valid_json"]}, command={item["command_match"]}', flush=True)
    report = {'examples':len(results), 'valid_json':sum(x['valid_json'] for x in results),
        'exact_command_matches':sum(x['command_match'] for x in results),
        'unexpected_actions':sum(x.get('unexpected_action',False) for x in results), 'note':'JSON and command validity are not intelligence scores. Blindly score correctness, relevance, language/dialect, context retention, and warmth (0-2 each). Compare base and adapter on the same holdouts.', 'results':results}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'Report: {args.report}')


if __name__ == '__main__':
    main()
