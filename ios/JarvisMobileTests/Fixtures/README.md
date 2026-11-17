# Real inference fixture

CI downloads `ggml-org/Qwen3-1.7B-GGUF` revision
`daeb8e2d528a760970442092f6bf1e55c3b659eb`, `Qwen3-1.7B-Q4_K_M.gguf`
(Apache-2.0), as `model.gguf`. Weights are ignored by Git.

`real-inference-required.txt` is created by CI. If that marker is bundled but
weights are absent, hosted tests fail. Without either file a developer run
explicitly skips real-inference tests. No synthetic model response is used.
