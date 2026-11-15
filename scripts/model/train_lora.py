#!/usr/bin/env python3
"""Train a JARVIS LoRA from an owner-local Qwen3 base model and curated JSONL.

Requires a compatible GPU environment; will not download models automatically.
The produced adapter/merged weights belong to the owner's derivative project,
subject to the base model's license.
"""
import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, help="LOCAL path to Qwen3 checkpoint")
    parser.add_argument("--train", type=Path, required=True, help="Curated train.jsonl")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=float, default=1.0)
    parser.add_argument("--lora-rank", type=int, default=16)
    parser.add_argument("--lora-alpha", type=int, default=32)
    parser.add_argument("--thinking", action="store_true",
                        help="Use Qwen's thinking-mode training template if desired")
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--accumulation", type=int, default=4)
    args = parser.parse_args()

    import torch
    from datasets import Dataset
    from peft import LoraConfig, get_peft_model
    from transformers import (
        AutoModelForCausalLM, AutoTokenizer, DataCollatorForSeq2Seq,
        Trainer, TrainingArguments
    )

    if not torch.cuda.is_available():
        raise SystemExit("Training requires a CUDA-capable GPU; iPhone inference is a separate step.")
    base = Path(args.base)
    if not base.is_dir():
        raise SystemExit("Provide a local base model directory. No remote model download is attempted.")

    tokenizer = AutoTokenizer.from_pretrained(str(base), local_files_only=True, trust_remote_code=False)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(
        str(base), local_files_only=True, trust_remote_code=False,
        torch_dtype=torch.float16, device_map="auto"
    )
    model.config.use_cache = False
    model = get_peft_model(model, LoraConfig(
        r=max(1, args.lora_rank), lora_alpha=max(1, args.lora_alpha),
        lora_dropout=0.05, bias="none",
        task_type="CAUSAL_LM", target_modules=[
            "q_proj", "k_proj", "v_proj", "o_proj",
            "gate_proj", "up_proj", "down_proj"
        ]
    ))

    examples = []
    for line in args.train.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        data = json.loads(line)
        prompt = tokenizer.apply_chat_template(
            [{"role": "user", "content": data["instruction"]}],
            tokenize=False, add_generation_prompt=True, enable_thinking=args.thinking
        )
        full = prompt + data["response"] + tokenizer.eos_token
        prompt_ids = tokenizer(prompt, add_special_tokens=False)["input_ids"]
        all_ids = tokenizer(full, add_special_tokens=False)["input_ids"]
        examples.append({
            "input_ids": all_ids,
            "attention_mask": [1] * len(all_ids),
            "labels": [-100] * len(prompt_ids) + all_ids[len(prompt_ids):],
        })
    if not examples:
        raise SystemExit("Training set is empty.")
    args.output.mkdir(parents=True, exist_ok=True)
    trainer = Trainer(
        model=model,
        args=TrainingArguments(
            output_dir=str(args.output / "checkpoints"),
            per_device_train_batch_size=max(1, args.batch_size),
            gradient_accumulation_steps=max(1, args.accumulation),
            num_train_epochs=args.epochs,
            save_strategy="epoch",
            logging_steps=10,
            report_to="none",
            remove_unused_columns=False,
            fp16=True
        ),
        train_dataset=Dataset.from_list(examples),
        data_collator=DataCollatorForSeq2Seq(
            tokenizer=tokenizer, padding=True, label_pad_token_id=-100,
            return_tensors="pt"
        ),
    )
    trainer.train()
    trainer.model.save_pretrained(args.output / "adapter")
    tokenizer.save_pretrained(args.output / "adapter")
    merged = trainer.model.merge_and_unload()
    merged.save_pretrained(args.output / "merged", safe_serialization=True)
    tokenizer.save_pretrained(args.output / "merged")
    print("LoRA saved locally. Convert merged model to compatible GGUF and verify iPhone inference.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
