#!/usr/bin/env bash
# Q-592: syntax-check the JNI C++ bridge (android/jni/llama_jni.cpp) so NDK / native regressions are
# caught in CI without a full device build. It needs an NDK clang and llama.cpp headers:
#   - locally: the Apple xcframework headers work (flat dir with llama.h + ggml*.h);
#   - in CI:   a shallow llama.cpp clone provides include/ and ggml/include/.
#
# Usage:  NDK_CLANG=<clang++> LLAMA_INCLUDE=<dir-with-llama.h> [GGML_INCLUDE=<dir>] scripts/check-jni-syntax.sh
# (NDK_CLANG defaults to any clang++ on PATH; GGML_INCLUDE defaults to LLAMA_INCLUDE for the flat layout.)
set -euo pipefail
cd "$(dirname "$0")/.."

CLANG="${NDK_CLANG:-$(command -v clang++ || true)}"
[ -n "$CLANG" ] || { echo "no clang++ found — set NDK_CLANG" >&2; exit 2; }
: "${LLAMA_INCLUDE:?set LLAMA_INCLUDE to a directory containing llama.h}"
GGML_INCLUDE="${GGML_INCLUDE:-$LLAMA_INCLUDE}"

echo "→ syntax-checking android/jni/llama_jni.cpp (target=aarch64-linux-android26)"
"$CLANG" --target=aarch64-linux-android26 -fsyntax-only -std=c++17 -Wall \
  -I android/jni -I "$LLAMA_INCLUDE" -I "$GGML_INCLUDE" \
  android/jni/llama_jni.cpp
echo "✓ JNI syntax OK"
