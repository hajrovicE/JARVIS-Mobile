import json
import tempfile
import unittest
from pathlib import Path

try:
    from .prepare_dataset import load_examples, partition, write_jsonl
except ImportError:
    from prepare_dataset import load_examples, partition, write_jsonl


class DatasetTests(unittest.TestCase):
    def test_requires_explicit_examples_and_does_not_modify_source(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "examples.jsonl"
            example = {"instruction": "Merhaba", "response": "Selam."}
            source.write_text(json.dumps(example, ensure_ascii=False) + "\n", encoding="utf-8")
            original = source.read_bytes()
            loaded = load_examples(source)
            self.assertEqual(loaded, [example])
            train, eval_set = partition(loaded)
            self.assertEqual(train, [example])
            self.assertEqual(eval_set, [])
            write_jsonl(Path(temp) / "train.jsonl", train)
            self.assertEqual(source.read_bytes(), original)

    def test_stable_deduplication_and_holdout(self):
        data = [{"instruction": f"Soru {i}", "response": f"Cevap {i}"} for i in range(20)]
        train, eval_set = partition(data + data[0:3])
        self.assertEqual((len(train), len(eval_set)), (18, 2))
        self.assertEqual((train, eval_set), partition(list(reversed(data)) + data[0:3]))
        self.assertTrue({row["instruction"] for row in train}.isdisjoint(
            {row["instruction"] for row in eval_set}))

    def test_rejects_empty_or_broken_data(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "broken.jsonl"
            for value in ('{"instruction":"a","response":""}', '{"bad":"row"}', "{invalid}"):
                path.write_text(value + "\n", encoding="utf-8")
                with self.assertRaises(ValueError):
                    load_examples(path)


if __name__ == "__main__":
    unittest.main()
