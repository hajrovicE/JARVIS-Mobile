#!/usr/bin/env python3
"""Convert explicit owner-authored examples into an offline JARVIS train/eval set.

No network access, automatic collection, background uploads or model calls.
Input: JSONL rows with non-empty instruction and response strings.
"""
import argparse
import hashlib
import json
from pathlib import Path


def load_examples(path: Path) -> list[dict[str, str]]:
    examples = []
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except ValueError as exc:
                raise ValueError(f"Invalid JSON at line {line_number}") from exc
            if not isinstance(value, dict):
                raise ValueError(f"Row {line_number}: expected object")
            instruction, response = value.get("instruction"), value.get("response")
            if not all(isinstance(item, str) and item.strip() for item in (instruction, response)):
                raise ValueError(f"Row {line_number}: nonempty instruction and response required")
            examples.append({"instruction": instruction, "response": response})
    if not examples:
        raise ValueError("No explicitly provided training examples")
    return examples


def partition(examples: list[dict[str, str]]) -> tuple[list[dict], list[dict]]:
    # Deterministic split: examples and ordering cannot trigger a network operation.
    unique: dict[str, dict[str, str]] = {}
    for example in examples:
        canonical = json.dumps(example, ensure_ascii=False, sort_keys=True)
        unique[hashlib.sha256(canonical.encode("utf-8")).hexdigest()] = example
    ordered = [unique[k] for k in sorted(unique)]
    if len(ordered) < 2:
        return ordered, []
    evaluation_count = max(1, len(ordered) // 10)
    return ordered[evaluation_count:], ordered[:evaluation_count]


def write_jsonl(path: Path, items: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as destination:
        for item in items:
            destination.write(json.dumps(item, ensure_ascii=False) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare JARVIS training data offline")
    parser.add_argument("--input", type=Path, required=True, help="Owner-created instruction/response JSONL")
    parser.add_argument("--output", type=Path, required=True, help="Local output directory")
    args = parser.parse_args()
    examples = load_examples(args.input)
    train, evaluation = partition(examples)
    args.output.mkdir(parents=True, exist_ok=True)
    write_jsonl(args.output / "train.jsonl", train)
    write_jsonl(args.output / "eval.jsonl", evaluation)
    print(f"Prepared {len(train)} train and {len(evaluation)} evaluation examples offline.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
