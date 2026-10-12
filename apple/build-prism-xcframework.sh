#!/usr/bin/env bash
# Build the pinned Bonsai runtime alongside the existing stock framework.
# Usage: apple/build-prism-xcframework.sh /absolute/new/work-directory
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
: "${1:?Pass a new work directory with at least 8 GB free}"
WORK="$1"
DEST="$HERE/QuenderinKit/Frameworks/prism-llama.xcframework"
if [ -e "$WORK" ] || [ -L "$WORK" ] || [ -e "$DEST" ] || [ -L "$DEST" ]; then
  echo "Choose a new work directory and preserve the existing framework." >&2
  exit 1
fi
AVAILABLE=$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')
if [ "$AVAILABLE" -lt 8388608 ]; then
  echo "Prism framework build requires at least 8 GB free; existing files are preserved." >&2
  exit 1
fi
python3 "$ROOT/scripts/prepare_prism_runtime.py" fetch --destination "$WORK/llama.cpp"
cd "$WORK/llama.cpp"
./build-xcframework.sh
python3 "$ROOT/scripts/prepare_prism_runtime.py" stamp --source "$PWD" --artifact "$PWD/build-apple/llama.xcframework"
mkdir -p "$(dirname "$DEST")"
cp -R build-apple/llama.xcframework "$DEST"
echo "Installed $DEST. Select with QUENDERIN_RUNTIME=prism for Xcode/Swift builds."
