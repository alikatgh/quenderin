#!/usr/bin/env bash
# Build `llama.xcframework` and drop it where QuenderinKit's Package.swift auto-links it.
#
# This is the "Route A" (shippable) path documented in Package.swift + INTEGRATION.md:
# a normal Xcode/device build of the app links real llama.cpp WITHOUT needing
# QUENDERIN_LLAMA_DIR. The xcframework carries device (arm64) + simulator + macOS slices
# with Metal embedded, so `#if canImport(llama)` flips true everywhere the app runs.
#
# We delegate the actual framework assembly (lib-merging, headers, module map, embedded
# Metal) to llama.cpp's own, known-good `build-xcframework.sh` — the same one the
# Package.swift comment points at — then copy its output into Frameworks/.
#
# Output (git-ignored, large binary): apple/QuenderinKit/Frameworks/llama.xcframework
# Distribute it to other machines/CI via a GitHub Release asset or Git LFS (see
# INTEGRATION.md) — it is intentionally NOT committed.
#
# Requirements: Xcode (xcodebuild), cmake, git, ~5 GB free disk. ~20–60 min on first run
# (compiles llama.cpp once per Apple slice).
#
# Usage:
#   apple/build-xcframework.sh [workdir]      # default workdir: /tmp/quenderin-xcframework
#   LLAMA_REF=b4000 apple/build-xcframework.sh   # pin a specific llama.cpp tag (recommended
#                                                #   for reproducible, API-matched builds)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/QuenderinKit/Frameworks"
WORK="${1:-/tmp/quenderin-xcframework}"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_REF="${LLAMA_REF:-master}"

mkdir -p "$WORK"; cd "$WORK"

echo "==> 1/3  Fetch llama.cpp ($LLAMA_REF)"
if [ ! -d llama.cpp ]; then
  git clone --depth 1 --branch "$LLAMA_REF" "$LLAMA_REPO" 2>/dev/null \
    || git clone --depth 1 "$LLAMA_REPO"   # fall back to default branch if ref isn't a branch/tag
fi
cd llama.cpp
echo "    at $(git rev-parse --short HEAD)"

echo "==> 2/3  Build llama.xcframework (device + simulator + macOS, Metal embedded)"
# llama.cpp ships this; it merges the ggml/llama static libs, writes the module map, and
# embeds the Metal library into each slice. This is the slow step.
chmod +x build-xcframework.sh
./build-xcframework.sh

if [ ! -d build-apple/llama.xcframework ]; then
  echo "!! build-apple/llama.xcframework not produced — check the build log above." >&2
  exit 1
fi

echo "==> 3/3  Install into QuenderinKit/Frameworks/"
mkdir -p "$DEST"
rm -rf "$DEST/llama.xcframework"
cp -R build-apple/llama.xcframework "$DEST/llama.xcframework"

echo
echo "✅ Installed $DEST/llama.xcframework"
echo "   Package.swift 'Route A' now auto-links it: a plain \`swift build\` / Xcode device"
echo "   build compiles LlamaEngine's real path — no QUENDERIN_LLAMA_DIR needed."
echo "   Verify:  cd apple/QuenderinKit && swift build && swift test"
echo "   (The .xcframework is git-ignored; publish it via a Release asset or LFS for CI.)"
