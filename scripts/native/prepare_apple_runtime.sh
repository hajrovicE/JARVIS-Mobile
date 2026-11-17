#!/usr/bin/env bash
# Pinned native dependency preparation only. No model/API/owner data/signing Secrets.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${1:?usage: prepare_apple_runtime.sh WORK_DIRECTORY [--device-only]}
MODE=${2:---with-simulator}
[[ "$MODE" == --with-simulator || "$MODE" == --device-only ]]
[[ $(uname -s) == Darwin ]]
mkdir -p "$WORK" "$ROOT/NativeRuntime/.artifacts"
WORK=$(cd "$WORK" && pwd)
ARCHIVE="$WORK/llama-b10549-xcframework.zip"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 --silent --show-error \
    https://github.com/ggml-org/llama.cpp/releases/download/b10549/llama-b10549-xcframework.zip \
    --output "$ARCHIVE.partial"
  mv "$ARCHIVE.partial" "$ARCHIVE"
fi
# This is the published SwiftPM dependency archive checksum, not an owner-model gate.
printf '%s  %s\n' 636709d4a7b49ac7f2ed6dc8a4de3f278c257cac7248fe40d6a513f671e4bff4 "$ARCHIVE" | shasum -a 256 -c -
mkdir -p "$WORK/upstream"
ditto -x -k "$ARCHIVE" "$WORK/upstream"
UPSTREAM=$(python3 - "$WORK/upstream" <<'PY'
import pathlib,sys
items=list(pathlib.Path(sys.argv[1]).rglob('llama.xcframework/Info.plist'))
if len(items)!=1: raise SystemExit('Expected one pinned upstream XCFramework')
print(items[0].parent)
PY
)
OUTPUT="$ROOT/NativeRuntime/.artifacts/llama.xcframework"
if [[ "$MODE" == --device-only ]]; then
  rm -rf "$OUTPUT"
  ditto "$UPSTREAM" "$OUTPUT"
  exit 0
fi
SIM_ARCH=$(uname -m)
[[ "$SIM_ARCH" == arm64 || "$SIM_ARCH" == x86_64 ]]
SOURCE="$WORK/source"
if [[ ! -d "$SOURCE/.git" ]]; then
  git clone --depth 1 --branch b10549 https://github.com/ggml-org/llama.cpp.git "$SOURCE"
fi
[[ $(git -C "$SOURCE" rev-parse HEAD) == b2e5e9b28b2484fbf94b543432ece638996a8b97 ]]
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
cmake -S "$SOURCE" -B "$WORK/simulator-build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES="$SIM_ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_ACCELERATE=OFF \
  -DGGML_OPENMP=OFF -DGGML_BACKEND_DL=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_MTMD=OFF -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF
cmake --build "$WORK/simulator-build" --target llama --parallel 3
LIBS=()
while IFS= read -r library; do LIBS+=("$library"); done < <(
  find "$WORK/simulator-build" -name libllama.a -o -name libggml.a -o -name libggml-base.a -o -name libggml-cpu.a
)
[[ ${#LIBS[@]} -eq 4 ]]
xcrun libtool -static -o "$WORK/libllama-combined.a" "${LIBS[@]}"
FRAMEWORK="$WORK/simulator/llama.framework"
mkdir -p "$FRAMEWORK/Headers" "$FRAMEWORK/Modules"
cp "$SOURCE/include/llama.h" "$FRAMEWORK/Headers/"
cp "$SOURCE/ggml/include/"*.h "$FRAMEWORK/Headers/"
cat > "$FRAMEWORK/Modules/module.modulemap" <<'MODULE'
framework module llama {
  umbrella header "llama.h"
  export *
  module * { export * }
}
MODULE
xcrun --sdk iphonesimulator clang++ -dynamiclib -arch "$SIM_ARCH" -isysroot "$SDK" \
  -mios-simulator-version-min=17.0 -Wl,-force_load,"$WORK/libllama-combined.a" \
  -framework Foundation -framework Accelerate -install_name @rpath/llama.framework/llama \
  -o "$FRAMEWORK/llama"
python3 - "$FRAMEWORK/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as output:
 plistlib.dump({'CFBundleExecutable':'llama','CFBundleIdentifier':'org.ggml.llama',
  'CFBundleName':'llama','CFBundlePackageType':'FMWK','CFBundleVersion':'10549',
  'CFBundleShortVersionString':'1.0','MinimumOSVersion':'17.0',
  'CFBundleSupportedPlatforms':['iPhoneSimulator'],'DTPlatformName':'iphonesimulator'},output)
PY
ARGS=()
while IFS= read -r framework; do ARGS+=(-framework "$framework"); done < <(
  python3 - "$UPSTREAM" <<'PY'
import pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])
data=plistlib.loads((root/'Info.plist').read_bytes())
for item in data['AvailableLibraries']:
 if item['SupportedPlatform']=='ios' and item.get('SupportedPlatformVariant')=='simulator': continue
 path=root/item['LibraryIdentifier']/item['LibraryPath']
 if path.suffix!='.framework' or not path.is_dir(): raise SystemExit('Unexpected pinned native artifact')
 print(path)
PY
)
[[ ${#ARGS[@]} -gt 0 ]]
rm -rf "$OUTPUT"
xcrun xcodebuild -create-xcframework "${ARGS[@]}" -framework "$FRAMEWORK" -output "$OUTPUT"
python3 - "$OUTPUT/Info.plist" "$SIM_ARCH" <<'PY'
import plistlib,sys
items=plistlib.load(open(sys.argv[1],'rb'))['AvailableLibraries']
assert any(x['SupportedPlatform']=='ios' and x.get('SupportedPlatformVariant')=='simulator' and sys.argv[2] in x['SupportedArchitectures'] for x in items)
assert any(x['SupportedPlatform']=='ios' and not x.get('SupportedPlatformVariant') for x in items)
print('Validated iPhone device and real native simulator slices:',sys.argv[2])
PY
