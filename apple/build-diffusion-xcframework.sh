#!/bin/bash
# Separate configure and dynamic framework: diffusion's patched GGML must never
# become a static duplicate of the llama runtime in the application executable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
: "${1:?Pass a new absolute session-owned work directory}"
WORK="$1"
case "$WORK" in /*) ;; *) echo "Absolute work path required" >&2; exit 1 ;; esac
test ! -e "$WORK" && test ! -L "$WORK" || { echo "Existing work path is preserved" >&2; exit 1; }
OUTPUT="$ROOT/apple/QuenderinKit/Frameworks/QuenderinDiffusion.xcframework"
test ! -e "$OUTPUT" && test ! -L "$OUTPUT" || { echo "Existing framework is preserved" >&2; exit 1; }
python3 - "$WORK" <<'PY'
import pathlib,shutil,sys
p=pathlib.Path(sys.argv[1]).parent
while not p.exists(): p=p.parent
if shutil.disk_usage(p).free < 6*1024**3: raise SystemExit('Diffusion build needs at least 6 GiB free')
PY
mkdir -p "$WORK"
python3 "$ROOT/scripts/prepare_diffusion_runtime.py" fetch --destination "$WORK/source"
PLATFORMS=(macos ios)
if [ "${CI_PRODUCT_PLATFORM:-}" = iOS ] && [ "${CI_XCODEBUILD_ACTION:-}" = build-for-testing ]; then
  PLATFORMS+=(ios-sim)
fi
FRAMEWORK_ARGS=()
for PLATFORM in "${PLATFORMS[@]}"; do
  case "$PLATFORM" in
    macos) SDK=macosx; ARCHS='arm64;x86_64'; MINIMUM=13.3; SYSTEM=Darwin ;;
    ios) SDK=iphoneos; ARCHS=arm64; MINIMUM=16.4; SYSTEM=iOS ;;
    ios-sim) SDK=iphonesimulator; ARCHS='arm64;x86_64'; MINIMUM=16.4; SYSTEM=iOS ;;
  esac
  cmake -S "$ROOT/native/diffusion" -B "$WORK/$PLATFORM" \
    -DDIFFUSION_SOURCE_DIR="$WORK/source" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$SYSTEM" -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCHS" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINIMUM" \
    -DQUENDERIN_DIFFUSION_BUILD_CLI=OFF
  cmake --build "$WORK/$PLATFORM" --target quenderin_diffusion --parallel 3
  python3 "$ROOT/scripts/prepare_diffusion_runtime.py" verify-library \
    --library "$WORK/$PLATFORM/bin/QuenderinDiffusion.framework/QuenderinDiffusion" --platform apple
  FRAMEWORK_ARGS+=(-framework "$WORK/$PLATFORM/bin/QuenderinDiffusion.framework")
done
mkdir -p "$(dirname "$OUTPUT")"
xcodebuild -create-xcframework "${FRAMEWORK_ARGS[@]}" -output "$OUTPUT"
python3 "$ROOT/scripts/verify_diffusion_apple_runtime.py" seal --framework "$OUTPUT"
