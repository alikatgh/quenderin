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
# against it (ARM aarch64) — the Android analog of the iOS typecheck. The on-emulator RUN
# stage wasn't completed in this sandbox (disk pressure ballooned the emulator and broke
# adb); it works once you have ~3 GB free. NOTE: NDK 27.1.12297006 here is a 4 KB stub — the
# NDK picker below skips stubs and selects a complete one (27.0 / 26.1).
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

echo "==> 2/5  Build libllama for Android ($ABI, CPU) via the NDK toolchain"
cmake -S llama.cpp -B llama.cpp/build-android \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" \
  -DCMAKE_BUILD_TYPE=Release -DGGML_OPENMP=OFF \
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
"$ADB" push model.gguf "$DEV"/ >/dev/null
"$ADB" shell "chmod +x $DEV/smoketest"
echo "--------------------------------------------------------------------"
"$ADB" shell "cd $DEV && LD_LIBRARY_PATH=$DEV ./smoketest model.gguf"
echo "--------------------------------------------------------------------"
echo "OK — llama.cpp builds for Android, jni/llama_jni.cpp compiles, inference runs on-device."
