#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
: "${1:?New absolute work directory required}"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to the established NDK}"
WORK="$1"
case "$WORK" in /*) ;; *) echo "Absolute work path required" >&2; exit 1 ;; esac
test ! -e "$WORK" && test ! -L "$WORK" || { echo "Existing build path is preserved" >&2; exit 1; }
mkdir -p "$WORK"
python3 "$ROOT/scripts/prepare_diffusion_runtime.py" fetch --destination "$WORK/source"
cmake -S "$ROOT/native/diffusion" -B "$WORK/build" \
  -DDIFFUSION_SOURCE_DIR="$WORK/source" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 -DANDROID_STL=c++_static \
  -DQUENDERIN_DIFFUSION_BUILD_CLI=OFF
cmake --build "$WORK/build" --target quenderin_diffusion quenderin_diffusion_jni --parallel 3
# Seal the final stripped bytes; AGP preserves these two already-stripped DSOs.
STRIP_TOOLS=( "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-strip )
test "${#STRIP_TOOLS[@]}" -eq 1 && test -x "${STRIP_TOOLS[0]}" || { echo "Exact NDK strip tool required" >&2; exit 1; }
"${STRIP_TOOLS[0]}" --strip-unneeded "$WORK/build/bin/libquenderin_diffusion.so" "$WORK/build/bin/libquenderin_diffusion_jni.so"
python3 "$ROOT/scripts/prepare_diffusion_runtime.py" verify-library \
  --library "$WORK/build/bin/libquenderin_diffusion.so" --platform elf
mkdir -p "$WORK/jniLibs/arm64-v8a"
cp "$WORK/build/bin/libquenderin_diffusion.so" "$WORK/build/bin/libquenderin_diffusion_jni.so" "$WORK/jniLibs/arm64-v8a/"
python3 - "$WORK/jniLibs" "$ROOT" <<'PY'
import hashlib,json,pathlib,sys
p,root=map(pathlib.Path,sys.argv[1:])
lock=json.loads((root/'shared/diffusion-runtime.json').read_text())
stamp={'version':1,'revision':lock['revision'],'abiVersion':lock['abiVersion'],
       'submodules':lock['submodules'],'androidStl':'c++_static',
       'files':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in (p/'arm64-v8a').glob('*.so')}}
(p/'quenderin-diffusion-runtime.json').write_text(json.dumps(stamp,indent=2)+'\n')
PY
python3 "$ROOT/scripts/verify_diffusion_android_package.py" --libraries "$WORK/jniLibs"
