#!/usr/bin/env python3
"""A conservative Qwen3-1.7B QLoRA profile for the GTX 1650 4 GB."""
import sys
from pathlib import Path
from train_gemma3_lora import main
if __name__=='__main__':
 sys.argv[1:1]=['--base-model','Qwen/Qwen3-1.7B','--profile','gtx1650','--max-length','512',
   '--dataset',str(Path(__file__).parent/'dataset/conversation_train.jsonl'),
   '--output-dir','outputs/smarthome-qwen3-1.7b','--epochs','1','--learning-rate','5e-5']
 main()
