#!/usr/bin/env bash
# Build the pinned Bonsai runtime alongside the existing stock framework.
# Usage: apple/build-prism-xcframework.sh /absolute/new/work-directory
# The pinned builder runs serial platform builds; no models are downloaded.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
: "${1:?Pass a new work directory with at least 8 GB free}"
case "$1" in
  /*) WORK="$1" ;;
  *) echo "The new work directory must be absolute." >&2; exit 1 ;;
esac
DEST="$HERE/QuenderinKit/Frameworks/prism-llama.xcframework"
if [ -e "$WORK" ] || [ -L "$WORK" ] || [ -e "$DEST" ] || [ -L "$DEST" ]; then
  echo "Choose a new work directory and preserve the existing framework." >&2
  exit 1
fi
WORK_PARENT="$WORK"
while [ ! -d "$WORK_PARENT" ]; do WORK_PARENT="$(dirname "$WORK_PARENT")"; done
AVAILABLE=$(df -Pk "$WORK_PARENT" | awk 'NR==2 {print $4}')
if [ "$AVAILABLE" -lt 8388608 ]; then
  echo "Prism framework build requires at least 8 GB free; existing files are preserved." >&2
  exit 1
fi
for TOOL in python3 git cmake xcrun; do
  command -v "$TOOL" >/dev/null || { echo "Missing prerequisite: $TOOL" >&2; exit 1; }
done
python3 "$ROOT/scripts/prepare_prism_runtime.py" fetch --destination "$WORK/llama.cpp"
cd "$WORK/llama.cpp"
# Do not build unused tvOS/visionOS/simulator platforms in a release job.
./build-xcframework.sh ios-device macos
python3 "$ROOT/scripts/prepare_prism_runtime.py" stamp --source "$PWD" --artifact "$PWD/build-apple/llama.xcframework"
python3 "$ROOT/scripts/verify_prism_apple_runtime.py" seal --framework "$PWD/build-apple/llama.xcframework"
mkdir -p "$(dirname "$DEST")"
# An atomic new destination also protects a framework created during the build.
mkdir "$DEST"
cp -R build-apple/llama.xcframework/. "$DEST/"
python3 "$ROOT/scripts/verify_prism_apple_runtime.py" verify-framework --framework "$DEST"
echo "Installed $DEST. Select with QUENDERIN_RUNTIME=prism for Xcode/Swift builds."
