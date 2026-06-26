#!/usr/bin/env bash
# Android analog of apple/verify-llama-link.sh. Builds llama.cpp for Android (NDK),
# compile-checks the JNI bridge (jni/llama_jni.cpp) against it, builds a native inference
# smoke test, and runs it on a booted emulator / attached device via adb. Mirrors the iOS
# twin — which IS proven end-to-end (Mac Metal + iPhone simulator).
#
# Requires: Android SDK + a FULL NDK (the clang++ toolchain), cmake, git, ~2 GB disk, and a
# booted emulator or attached device for the run step.
#   "$SDK/cmdline-tools/latest/bin/sdkmanager" "ndk;27.1.12297006"   # if the NDK is a stub
#   "$SDK/emulator/emulator" -avd Pixel_6a &                          # boot an emulator
#   QUENDERIN_MODEL=~/models/qwen.gguf  android/verify-llama-link.sh  # use your model, 0 download
#
# VERIFIED 2026-06-07 (build + compile stages): with NDK 27.0.12077973, libllama.so built
# for Android arm64-v8a, AND `jni/llama_jni.cpp` + `tools/llama-smoketest.cpp` BOTH compiled
# against it (ARM aarch64) — the Android analog of the iOS typecheck.
# VERIFIED END-TO-END 2026-06-14 (NDK r26d / 26.3.11579264): the full RUN stage completed on a
# booted arm64 emulator — coherent output ("the sky is blue because…"), ~102 tok/s decode (CPU).
# NOTE: some NDK installs leave a 4 KB stub — the NDK picker below skips stubs and selects a
# complete one. The smoke test links libc++_shared.so dynamically, so step 5 now pushes it too.
set -euo pipefail

WORK="${1:-/tmp/quenderin-llama-android}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ABI="${ABI:-arm64-v8a}"          # arm64-v8a: real phones + Apple-silicon emulators
API="${API:-28}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
# Pick a COMPLETE NDK (with a clang++) newest-first — some installs leave 4 KB stubs.
NDK="${ANDROID_NDK:-}"
if [ -z "$NDK" ]; then
  for d in $(ls -d "$SDK"/ndk/* 2>/dev/null | sort -rV); do
    if ls "$d"/toolchains/llvm/prebuilt/*/bin/clang++ >/dev/null 2>&1; then NDK="$d"; break; fi
  done
fi
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true"

PREBUILT="$(ls "$NDK/toolchains/llvm/prebuilt" 2>/dev/null | head -1 || true)"
CLANG="$NDK/toolchains/llvm/prebuilt/$PREBUILT/bin/clang++"
if [ -z "$PREBUILT" ] || [ ! -x "$CLANG" ]; then
  echo "ERROR: NDK toolchain not found under $NDK (a stub?). Install it, then re-run:"
  echo "  \"$SDK/cmdline-tools/latest/bin/sdkmanager\" \"ndk;27.1.12297006\""
  exit 1
fi

mkdir -p "$WORK"; cd "$WORK"
echo "==> 1/5  Clone llama.cpp (shallow)"
[ -d llama.cpp ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp.git

# GPU offload (Vulkan) is opt-in: `QUENDERIN_VULKAN=1 ./verify-llama-link.sh` builds the Vulkan backend
# and runs the on-device smoke with n_gpu_layers=999 so you can A/B against the CPU baseline on a real
# device (e.g. a Snapdragon/Adreno S23). Default = CPU build, unchanged.
if [ "${QUENDERIN_VULKAN:-0}" = "1" ]; then
  GPU_CMAKE="-DGGML_VULKAN=ON"; SMOKE_GPU_LAYERS=999; MODE="CPU + Vulkan GPU"
else
  GPU_CMAKE="";                 SMOKE_GPU_LAYERS=0;   MODE="CPU"
fi
echo "==> 2/5  Build libllama for Android ($ABI, $MODE) via the NDK toolchain"
cmake -S llama.cpp -B llama.cpp/build-android \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" \
  -DCMAKE_BUILD_TYPE=Release -DGGML_OPENMP=OFF $GPU_CMAKE \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_CURL=OFF >/dev/null
cmake --build llama.cpp/build-android --target llama -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >/dev/null
echo "    built $(ls llama.cpp/build-android/bin/libllama.so)"

echo "==> 3/5  Compile-check the JNI bridge against real llama.cpp ($ABI)"
"$CLANG" --target="aarch64-linux-android$API" -std=c++17 -c "$HERE/jni/llama_jni.cpp" \
  -I"$WORK/llama.cpp/include" -I"$WORK/llama.cpp/ggml/include" -o "$WORK/llama_jni.o"
echo "    jni/llama_jni.cpp compiles for Android  (libquenderin_llama.so = it + libllama)"

echo "==> 4/5  Build the native inference smoke test"
"$CLANG" --target="aarch64-linux-android$API" -O3 -std=c++17 "$HERE/tools/llama-smoketest.cpp" \
  -I"$WORK/llama.cpp/include" -I"$WORK/llama.cpp/ggml/include" \
  -L"$WORK/llama.cpp/build-android/bin" -lllama -o smoketest

echo "==> 5/5  Push + run on the device (needs a booted emulator/device)"
if [ -n "${QUENDERIN_MODEL:-}" ]; then
  ln -sf "$QUENDERIN_MODEL" model.gguf            # use YOUR model — no download
elif [ ! -f model.gguf ]; then
  echo "    (set QUENDERIN_MODEL=/path/to/your.gguf to skip this download)"
  curl -L -s -o model.gguf "$MODEL_URL"
fi
ADB="$SDK/platform-tools/adb"; DEV="/data/local/tmp/quenderin"
"$ADB" shell mkdir -p "$DEV"
"$ADB" push smoketest "$DEV"/ >/dev/null
"$ADB" push llama.cpp/build-android/bin/*.so "$DEV"/ >/dev/null
# The smoketest dynamically links libc++_shared.so (NDK C++ runtime) — push it from the NDK
# sysroot or the run fails with: CANNOT LINK EXECUTABLE … library "libc++_shared.so" not found.
LIBCXX="$NDK/toolchains/llvm/prebuilt/$PREBUILT/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
[ -f "$LIBCXX" ] && "$ADB" push "$LIBCXX" "$DEV"/ >/dev/null
"$ADB" push model.gguf "$DEV"/ >/dev/null
"$ADB" shell "chmod +x $DEV/smoketest"
echo "--------------------------------------------------------------------"
# Capture the run so we can gate on its result explicitly (adb shell exit-code propagation is
# historically unreliable). The smoke test prints PASS/FAIL for the KV-reuse equivalence check.
SMOKE_OUT="$("$ADB" shell "cd $DEV && LD_LIBRARY_PATH=$DEV ./smoketest model.gguf 'Write three sentences about why the sky is blue.' 96 $SMOKE_GPU_LAYERS")" || true
echo "$SMOKE_OUT"
echo "--------------------------------------------------------------------"
if echo "$SMOKE_OUT" | grep -q "FAIL:"; then
  echo "ERROR: on-device smoke test reported a FAILURE (see above)." >&2
  exit 1
fi
if ! echo "$SMOKE_OUT" | grep -q "PASS: KV-reuse"; then
  echo "ERROR: smoke test did not reach the KV-reuse equivalence PASS — the shipped decode path was" >&2
  echo "       not validated end-to-end. Check the run output above." >&2
  exit 1
fi
echo "OK — llama.cpp builds for Android, jni/llama_jni.cpp compiles, inference runs on-device,"
echo "     and the shared KV-reuse decode path matches a full prefill (multi-turn equivalence)."
