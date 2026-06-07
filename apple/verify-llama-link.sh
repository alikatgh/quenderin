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
# Requirements: Xcode (swiftc), cmake, git, ~2 GB free disk, network for the model.
# Usage: apple/verify-llama-link.sh [workdir]   (default: /tmp/quenderin-llama-verify)
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

echo "==> 3/4  Fetch a tiny model (~0.47 GB) if missing"
[ -f model.gguf ] || curl -L -s -o model.gguf "$MODEL_URL"

echo "==> 4/4  Compile + run the Swift smoke test against real llama.cpp (Metal)"
mkdir -p cllama
cat > cllama/module.modulemap <<MAP
module llama {
    header "$WORK/llama.cpp/include/llama.h"
    export *
}
MAP
swiftc -O "$HERE/tools/llama-smoketest.swift" \
  -Xcc -fmodule-map-file="$WORK/cllama/module.modulemap" \
  -Xcc -I"$WORK/llama.cpp/include" -Xcc -I"$WORK/llama.cpp/ggml/include" \
  -I"$WORK/cllama" \
  -L"$WORK/llama.cpp/build/bin" -lllama \
  -o smoketest
echo "--------------------------------------------------------------------"
DYLD_LIBRARY_PATH="$WORK/llama.cpp/build/bin" ./smoketest model.gguf
echo "--------------------------------------------------------------------"
echo "OK — Swift <-> llama.cpp verified end to end (compile + link + Metal + inference)."
echo "To wire into QuenderinKit: add a system-library target for 'llama' (the modulemap"
echo "above) and link libllama; LlamaEngine's '#if canImport(llama)' path then compiles."
echo "See apple/QuenderinKit/INTEGRATION.md."
