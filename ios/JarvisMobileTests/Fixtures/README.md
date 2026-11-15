# Real inference fixture

CI downloads `ggml-org/Qwen3-0.6B-GGUF` revision
`afe8ad3577aa22500b3cd1c880f153b3b0e1cae8`, `Qwen3-0.6B-Q4_0.gguf`
(Apache-2.0), as `model.gguf`. Weights are ignored by Git.

`real-inference-required.txt` is created by CI. If that marker is bundled but
weights are absent, hosted tests fail. Without either file a developer run
explicitly skips real-inference tests. No synthetic model response is used.
