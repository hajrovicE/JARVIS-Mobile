#!/usr/bin/env bash
# Public test weights only. No API keys, cloud inference or owner data.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TASK_WORK=${1:?usage: verify_runtime.sh WORK_DIRECTORY}
mkdir -p "$TASK_WORK"
TASK_WORK=$(cd "$TASK_WORK" && pwd)
CMAKE=${CMAKE:-cmake}
SWIFT=${SWIFT:-swift}
NINJA=${NINJA:-ninja}
MODEL_FILE="$TASK_WORK/qwen3-1.7b-q4_k_m.gguf"
if [[ ! -d "$TASK_WORK/llama.cpp/.git" ]]; then
  git clone --depth 1 --branch b10549 https://github.com/ggml-org/llama.cpp.git "$TASK_WORK/llama.cpp"
fi
[[ $(git -C "$TASK_WORK/llama.cpp" rev-parse HEAD) == b2e5e9b28b2484fbf94b543432ece638996a8b97 ]]
"$CMAKE" -S "$TASK_WORK/llama.cpp" -B "$TASK_WORK/llama-build" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$NINJA" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DGGML_NATIVE=OFF -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_METAL=OFF \
  -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF
"$CMAKE" --build "$TASK_WORK/llama-build" --target llama --parallel 2
if [[ ! -f "$MODEL_FILE" ]]; then
  curl --fail --location --retry 3 \
    'https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/daeb8e2d528a760970442092f6bf1e55c3b659eb/Qwen3-1.7B-Q4_K_M.gguf' \
    --output "$MODEL_FILE.partial"
  mv "$MODEL_FILE.partial" "$MODEL_FILE"
fi
mkdir -p "$TASK_WORK/harness/CLlama" "$TASK_WORK/harness/Sources/RuntimeProof"
# Paths are inserted as JSON/Swift quoted strings, never evaluated by a shell.
python3 - "$ROOT" "$TASK_WORK" <<'PY'
import json, pathlib, sys
root, work = map(pathlib.Path, sys.argv[1:])
harness = work / 'harness'
(harness / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RuntimeProof", dependencies: [.package(path: %s)], targets: [
 .systemLibrary(name: "LlamaSwift", path: "CLlama"),
 .executableTarget(name: "RuntimeProof", dependencies: ["LlamaSwift", .product(name: "JarvisCore", package: "JARVIS-Mobile")], sources: ["GGUFInferenceRuntime.swift", "RuntimeHarness.swift"])
])
''' % json.dumps(str(root)))
(harness / 'CLlama/module.modulemap').write_text('module LlamaSwift { header %s\n link "llama"\n export *\n}\n' % json.dumps(str(work / 'llama.cpp/include/llama.h')))
PY
cp "$ROOT/ios/JarvisMobile/GGUFInferenceRuntime.swift" "$TASK_WORK/harness/Sources/RuntimeProof/"
cp "$ROOT/scripts/model/RuntimeHarness.swift" "$TASK_WORK/harness/Sources/RuntimeProof/"
cmp "$ROOT/ios/JarvisMobile/GGUFInferenceRuntime.swift" "$TASK_WORK/harness/Sources/RuntimeProof/GGUFInferenceRuntime.swift"
"$SWIFT" build --package-path "$TASK_WORK/harness" \
  --cache-path "$TASK_WORK/swift-cache" --config-path "$TASK_WORK/swift-config" --security-path "$TASK_WORK/swift-security" \
  -Xcc "-I$TASK_WORK/llama.cpp/ggml/include" \
  -Xlinker "-L$TASK_WORK/llama-build/bin" -Xlinker -rpath -Xlinker "$TASK_WORK/llama-build/bin"
"$TASK_WORK/harness/.build/debug/RuntimeProof" "$MODEL_FILE"
