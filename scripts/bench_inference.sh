#!/usr/bin/env bash
# Inference SLO harness — the numbers behind docs/INFERENCE_SLO.md ("run local models like a paid
# cloud service"). Builds the VENDORED llama.cpp pin (android/jni/llama.cpp — the engine we ship, not
# upstream HEAD) once, then measures, per model:
#
#   1. raw ceilings   — llama-bench pp512 (prefill) / tg128 (decode) / tg512 (sustained decode)
#   2. first-token    — android/tools/llama-smoketest.cpp --ttft in a FRESH process, cold vs warmed
#                       (the cliff the engines' load-time warmup removes)
#   3. shipped loop   — the smoke test's PASS/FAIL gates on the exact generate loop the JNI ships
#                       (KV-reuse equivalence, chunked prefill > n_batch, over-length clamp)
#
# Built to catch: the Android >n_batch SIGABRT (llama_generate.h decodeChunked), a regression of the
# cold-start cliff (warmupContext / warmUpLocked), and silent decode/prefill regressions across llama.cpp
# pin bumps. Does NOT catch: UI-thread stalls (per-token re-render), thermal collapse over minutes, or
# model quality — those need the app on a device and a human/eval respectively.
#
# Usage (from repo root):
#   scripts/bench_inference.sh mac     [model.gguf ...]     # Metal, this Mac
#   scripts/bench_inference.sh android [model.gguf ...]     # NDK build, pushed to the attached device
# Models default to every *.gguf in ~/.quenderin/models. Work dir: $QUENDERIN_BENCH_WORK
# (default /tmp/quenderin-bench). Append the printed rows to docs/BENCH_BASELINE.md.
set -euo pipefail

MODE="${1:-mac}"; shift || true
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$HERE/android/jni/llama.cpp"
WORK="${QUENDERIN_BENCH_WORK:-/tmp/quenderin-bench}"
mkdir -p "$WORK"
if [ "$#" -gt 0 ]; then MODELS=("$@"); else MODELS=("$HOME"/.quenderin/models/*.gguf); fi
[ -e "${MODELS[0]}" ] || { echo "no models — download one via the app or pass a .gguf path" >&2; exit 2; }

TOOLS="-DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_CURL=OFF"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

case "$MODE" in
mac)
  B="$WORK/mac"
  if [ ! -x "$B/bin/llama-bench" ]; then
    echo "==> building vendored llama.cpp pin for macOS (Metal)"
    cmake -S "$PIN" -B "$B" -DGGML_METAL=ON -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release $TOOLS >/dev/null
    cmake --build "$B" --target llama-bench -j"$NCPU" >/dev/null
  fi
  if [ ! -x "$WORK/smoketest-mac" ] || [ "$HERE/android/tools/llama-smoketest.cpp" -nt "$WORK/smoketest-mac" ] \
     || [ "$HERE/android/jni/llama_generate.h" -nt "$WORK/smoketest-mac" ]; then
    clang++ -std=c++17 -O2 "$HERE/android/tools/llama-smoketest.cpp" -I"$PIN/include" -I"$PIN/ggml/include" \
      -L"$B/bin" -lllama -lggml -lggml-base -Wl,-rpath,"$B/bin" -o "$WORK/smoketest-mac"
  fi
  # ThreadPlanner picks the P-core count; mirror it (falls back to all cores − 1).
  T="$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo $((NCPU - 1)))"
  echo "load average now: $(uptime | sed 's/.*load averages*: //') — numbers are noisy above ~$NCPU"
  for M in "${MODELS[@]}"; do
    echo; echo "=== $(basename "$M") — Metal, all layers, $T threads ==="
    "$B/bin/llama-bench" -m "$M" -ngl 999 -t "$T" -p 512 -n 128,512 -r 3 2>/dev/null | grep -E '^\| [a-z]' | grep -v '| model' \
      | awk -F'|' '{printf "  %-8s %s tok/s\n", $7, $8}'
    for i in 1 2; do
      "$WORK/smoketest-mac" "$M" --ttft cold 999 2>/dev/null | sed 's/^/  /'
      "$WORK/smoketest-mac" "$M" --ttft warm 999 2>/dev/null | sed 's/^/  /'
    done
    "$WORK/smoketest-mac" "$M" "Write three sentences about why the sky is blue." 48 999 2>/dev/null \
      | grep -E '^(REAL|PASS|FAIL)' | sed 's/^/  /'
  done
  ;;
android)
  SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  NDK="${ANDROID_NDK:-}"
  if [ -z "$NDK" ]; then
    for d in $(ls -d "$SDK"/ndk/* 2>/dev/null | sort -rV); do
      ls "$d"/toolchains/llvm/prebuilt/*/bin/clang++ >/dev/null 2>&1 && { NDK="$d"; break; }   # skip 4 KB stubs
    done
  fi
  [ -n "$NDK" ] || { echo "no complete NDK under $SDK/ndk" >&2; exit 2; }
  CL="$(ls "$NDK"/toolchains/llvm/prebuilt/*/bin/clang++ | head -1)"
  B="$WORK/android"
  if [ ! -x "$B/bin/llama-bench" ]; then
    echo "==> building vendored llama.cpp pin for Android arm64 (app flags: CPU variants + backend DL)"
    cmake -S "$PIN" -B "$B" -DCMAKE_MAKE_PROGRAM="$(command -v make)" \
      -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI=arm64-v8a \
      -DANDROID_PLATFORM=android-28 -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      "-DCMAKE_C_FLAGS_RELWITHDEBINFO=-O3 -g -DNDEBUG" "-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-O3 -g -DNDEBUG" \
      -DGGML_OPENMP=OFF -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON $TOOLS >/dev/null
    cmake --build "$B" --target llama-bench -j"$NCPU" >/dev/null
  fi
  "$CL" --target=aarch64-linux-android28 -O3 -std=c++17 "$HERE/android/tools/llama-smoketest.cpp" \
    -I"$PIN/include" -I"$PIN/ggml/include" -L"$B/bin" -lllama -lggml -lggml-base -llog -o "$WORK/smoketest-android"
  ADB="$SDK/platform-tools/adb"; DEV="/data/local/tmp/quenderin"
  SERIAL="${ANDROID_SERIAL:-$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')}"
  [ -n "$SERIAL" ] || { echo "no attached device (adb devices)" >&2; exit 2; }
  A="$ADB -s $SERIAL"
  # Shared test phone: never disturb whatever is in the foreground, and don't measure a hot SoC —
  # thermal throttling makes every number a lie (docs/MOBILE_PERFORMANCE_101.md).
  TEMP="$($A shell dumpsys battery | awk '/temperature/{print $2}')"
  FG="$($A shell dumpsys activity activities | grep -m1 topResumedActivity | sed 's/.*u0 //; s/ .*//')"
  echo "device $SERIAL  soc=$($A shell getprop ro.soc.model | tr -d '\r')  battery=$((TEMP/10)).$((TEMP%10))°C  foreground=$FG"
  if [ "${TEMP:-0}" -gt 380 ] && [ "${QUENDERIN_BENCH_HOT_OK:-0}" != "1" ]; then
    echo "battery > 38°C — results would be throttled; let it cool or set QUENDERIN_BENCH_HOT_OK=1" >&2; exit 3
  fi
  $A shell mkdir -p "$DEV"
  $A push "$B"/bin/llama-bench "$WORK/smoketest-android" "$B"/bin/*.so "$DEV/" >/dev/null
  $A push "$NDK"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so "$DEV/" >/dev/null
  $A shell "chmod +x $DEV/llama-bench $DEV/smoketest-android"
  for M in "${MODELS[@]}"; do
    N="$(basename "$M")"
    $A shell "[ -f $DEV/$N ]" || $A push "$M" "$DEV/$N" >/dev/null
    echo; echo "=== $N — CPU, variant backends from $DEV ==="
    # GGML_BACKEND_DIR is where ggml_backend_load_all looks for the libggml-cpu-*.so variants.
    ENV="cd $DEV && LD_LIBRARY_PATH=$DEV GGML_BACKEND_DIR=$DEV"
    $A shell "$ENV ./llama-bench -m $N -t 4 -p 512 -n 128,512 -r 3 2>/dev/null" | grep -E '^\| [a-z]' | grep -v '| model' \
      | awk -F'|' '{printf "  %-8s %s tok/s\n", $7, $8}'
    for i in 1 2; do
      $A shell "$ENV ./smoketest-android $N --ttft cold 2>/dev/null" | grep TTFT | sed 's/^/  /'
      $A shell "$ENV ./smoketest-android $N --ttft warm 2>/dev/null" | grep TTFT | sed 's/^/  /'
    done
    $A shell "$ENV ./smoketest-android $N 'Write three sentences about why the sky is blue.' 48 2>/dev/null" \
      | grep -E '^(REAL|PASS|FAIL)' | sed 's/^/  /'
    echo "  battery after: $(($($A shell dumpsys battery | awk '/temperature/{print $2}')/10))°C"
  done
  ;;
*) echo "usage: $0 mac|android [model.gguf ...]" >&2; exit 2 ;;
esac
