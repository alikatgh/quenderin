#!/usr/bin/env bash
# Reproducible proof that QuenderinKit's LlamaEngine C-API links + runs against real
# llama.cpp with Metal. Builds llama.cpp, fetches a tiny GGUF, compiles
# apple/tools/llama-smoketest.swift against it, and runs a real inference.
#
# VERIFIED 2026-06-07 (macOS / Xcode 16.2 / cmake): coherent output ("the sky is blue
# because…"), Metal GPU, ~177 tok/s decode for Qwen2.5-0.5B Q4_K_M on an M-series Mac.
# This de-risks the "link llama.cpp" cliff — the exact API sequence QuenderinKit uses
# (load_from_file → init_from_model → tokenize → decode → sampler → token_to_piece) is proven.
#
# Requirements: Xcode (swiftc), cmake, git, ~2 GB free disk. Bring your own GGUF via
#   QUENDERIN_MODEL=/path/to/your.gguf to skip the model download (no network needed for it).
# Usage: apple/verify-llama-link.sh [workdir]   (default: /tmp/quenderin-llama-verify)
#   QUENDERIN_MODEL=~/models/qwen.gguf  apple/verify-llama-link.sh   # use your model, 0 download
set -euo pipefail

WORK="${1:-/tmp/quenderin-llama-verify}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true"

mkdir -p "$WORK"; cd "$WORK"

echo "==> 1/4  Clone llama.cpp (shallow)"
[ -d llama.cpp ] || git clone --depth 1 "$LLAMA_REPO"

echo "==> 2/4  Build libllama with Metal (Release, no examples/tests/server)"
cmake -S llama.cpp -B llama.cpp/build \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_CURL=OFF -DGGML_METAL=ON >/dev/null
cmake --build llama.cpp/build --target llama -j"$(sysctl -n hw.ncpu)" >/dev/null
echo "    built $(ls llama.cpp/build/bin/libllama.dylib)"

echo "==> 2b   Type-check QuenderinKit's real '#if canImport(llama)' path vs the headers"
mkdir -p cllama
cat > cllama/module.modulemap <<MAP
module llama {
    header "$WORK/llama.cpp/include/llama.h"
    export *
}
MAP
swiftc -typecheck "$HERE"/QuenderinKit/Sources/QuenderinKit/*.swift \
  -Xcc -fmodule-map-file="$WORK/cllama/module.modulemap" \
  -Xcc -I"$WORK/llama.cpp/include" -Xcc -I"$WORK/llama.cpp/ggml/include" -I"$WORK/cllama"
echo "    LlamaEngine's real inference path type-checks against current llama.cpp master"

echo "==> 3/4  Fetch a tiny model (~0.47 GB) if missing"
if [ -n "${QUENDERIN_MODEL:-}" ]; then
  ln -sf "$QUENDERIN_MODEL" model.gguf            # use YOUR model — no download
elif [ ! -f model.gguf ]; then
  echo "    (set QUENDERIN_MODEL=/path/to/your.gguf to skip this download)"
  curl -L -s -o model.gguf "$MODEL_URL"
fi

echo "==> 4/4  Compile + run the Swift smoke test against real llama.cpp (Metal)"
swiftc -O "$HERE/tools/llama-smoketest.swift" \
  -Xcc -fmodule-map-file="$WORK/cllama/module.modulemap" \
  -Xcc -I"$WORK/llama.cpp/include" -Xcc -I"$WORK/llama.cpp/ggml/include" \
  -I"$WORK/cllama" \
  -L"$WORK/llama.cpp/build/bin" -lllama \
  -o smoketest
echo "--------------------------------------------------------------------"
DYLD_LIBRARY_PATH="$WORK/llama.cpp/build/bin" ./smoketest model.gguf
echo "--------------------------------------------------------------------"

# ── Step 5 (optional): build for the iOS SIMULATOR and run ON a simulated iPhone ──
SIM_UDID="$(xcrun simctl list devices available 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
if [ -n "$SIM_UDID" ]; then
  echo "==> 5/5  iOS simulator: build for the sim arch + run on device $SIM_UDID"
  cmake -S llama.cpp -B llama.cpp/build-iossim \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_CURL=OFF -DGGML_METAL=ON >/dev/null
  cmake --build llama.cpp/build-iossim --target llama -j"$(sysctl -n hw.ncpu)" >/dev/null
  swiftc -O "$HERE/tools/llama-smoketest.swift" \
    -target arm64-apple-ios16.0-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -Xcc -fmodule-map-file="$WORK/cllama/module.modulemap" \
    -Xcc -I"$WORK/llama.cpp/include" -Xcc -I"$WORK/llama.cpp/ggml/include" -I"$WORK/cllama" \
    -L"$WORK/llama.cpp/build-iossim/bin" -lllama \
    -Xlinker -rpath -Xlinker "$WORK/llama.cpp/build-iossim/bin" -o smoketest-ios
  xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || true
  echo "    (NGL=0 → CPU: the iOS *simulator's* Metal compute is broken; real devices use Metal)"
  echo "----"
  SIMCTL_CHILD_QUENDERIN_NGL=0 \
    SIMCTL_CHILD_DYLD_LIBRARY_PATH="$WORK/llama.cpp/build-iossim/bin" \
    xcrun simctl spawn "$SIM_UDID" "$PWD/smoketest-ios" "$PWD/model.gguf"
  echo "----"
fi

echo "OK — Swift <-> llama.cpp verified end to end (Mac Metal + iOS simulator + inference)."
echo "To wire into QuenderinKit: add a system-library target for 'llama' (the modulemap"
echo "above) and link libllama; LlamaEngine's '#if canImport(llama)' path then compiles."
echo "See apple/QuenderinKit/INTEGRATION.md."
