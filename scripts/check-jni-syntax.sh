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

# llama.cpp replaced use_mmap/use_mlock with enum load_mode — detect from headers so the dual
# path in llama_jni.cpp compiles against both the vendored pin and ggml-org HEAD (CI).
EXTRA_DEFS=()
# Match the enum (not llama_load_model_from_file — "llama_load_mode" is a prefix of that name).
if grep -qE 'enum[[:space:]]+llama_load_mode|LLAMA_LOAD_MODE_MMAP' "$LLAMA_INCLUDE/llama.h" 2>/dev/null; then
  EXTRA_DEFS+=(-DQUENDERIN_LLAMA_LOAD_MODE=1)
  echo "→ llama.cpp load_mode API detected"
else
  echo "→ llama.cpp legacy use_mmap/use_mlock API"
fi

# llama_sampler_init_penalties gained n_vocab as its FIRST arg (5 args) after the vendored pin
# (4 args). Extract the declaration up to its closing paren and look for n_vocab.
if awk '/llama_sampler_init_penalties\(/{f=1} f{print} f&&/\)/{exit}' "$LLAMA_INCLUDE/llama.h" 2>/dev/null | grep -q 'n_vocab'; then
  EXTRA_DEFS+=(-DQUENDERIN_LLAMA_PENALTIES_VOCAB=1)
  echo "→ llama.cpp penalties(n_vocab, ...) API detected"
else
  echo "→ llama.cpp legacy penalties(...) API"
fi

echo "→ syntax-checking android/jni/llama_jni.cpp (target=aarch64-linux-android26)"
# "${arr[@]+"${arr[@]}"}" is empty-safe under `set -u` when EXTRA_DEFS has no elements.
"$CLANG" --target=aarch64-linux-android26 -fsyntax-only -std=c++17 -Wall \
  -I android/jni -I "$LLAMA_INCLUDE" -I "$GGML_INCLUDE" \
  ${EXTRA_DEFS[@]+"${EXTRA_DEFS[@]}"} \
  android/jni/llama_jni.cpp
echo "✓ JNI syntax OK"
