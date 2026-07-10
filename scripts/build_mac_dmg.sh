#!/bin/bash
# Build the native macOS app (QuenderinMac) and package it as a local test DMG.
#
# Why this script exists: the 2026-07-09 session hand-rolled this exact sequence
# (xcodegen → xcodebuild → staging → hdiutil) to produce
# apple/QuenderinApp/build/Quenderin-0.2.0-native-macOS.dmg; second occurrence
# promotes it here (global CLAUDE.md §2). It builds the LOCAL-TEST artifact only —
# the public macOS channel is the Mac App Store (docs/MAC_APP_STORE.md); do NOT
# publish this DMG on the website.
#
# What it does not catch: no notarization, no App Store validation, dev/ad-hoc
# signing only — the DMG is for running on this machine ("let's see"), not shipping.
#
# Usage: scripts/build_mac_dmg.sh [Release|Debug]   (default Release)
set -euo pipefail

CONFIG="${1:-Release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/apple/QuenderinApp"
BUILD="$APP_DIR/build"
SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
VERSION="$(grep -m1 'MARKETING_VERSION' "$APP_DIR/project.yml" | sed 's/[^0-9.]//g')"
DMG="$BUILD/Quenderin-${VERSION}-${SHA}-native-macOS.dmg"

cd "$APP_DIR"
echo "── xcodegen (project.yml → Quenderin.xcodeproj)"
xcodegen >/dev/null

echo "── xcodebuild QuenderinMac ($CONFIG)"
xcodebuild -project Quenderin.xcodeproj -scheme QuenderinMac -configuration "$CONFIG" \
    -derivedDataPath "$BUILD/DerivedData" -destination 'platform=macOS' \
    build 2>&1 | tail -3

APP="$BUILD/DerivedData/Build/Products/$CONFIG/Quenderin.app"
[ -d "$APP" ] || { echo "FATAL: $APP not found"; exit 1; }

echo "── staging"
rm -rf "$BUILD/dmg-staging" "$DMG"
mkdir -p "$BUILD/dmg-staging"
cp -R "$APP" "$BUILD/dmg-staging/"
ln -s /Applications "$BUILD/dmg-staging/Applications"

# ── re-sign CONSISTENTLY, or dyld kills the app at launch ─────────────────────
# The Release build signs with HARDENED RUNTIME (flags 0x10002 adhoc,runtime).
# Hardened runtime enforces library validation: the embedded llama.framework must
# carry the SAME Team ID as the process — adhoc has none, so launch dies with
# "Library not loaded … different Team IDs" (bug journal 2026-07-10). Sign the
# framework FIRST, then the app (outside-in order invalidates the nested seal),
# with a real dev identity when the keychain has one, else adhoc WITHOUT the
# hardened-runtime flag (no runtime ⇒ no library validation ⇒ adhoc+adhoc loads).
STAGED="$BUILD/dmg-staging/Quenderin.app"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    echo "── codesign (identity: $IDENTITY)"
    codesign --force --sign "$IDENTITY" --timestamp=none "$STAGED/Contents/Frameworks/llama.framework/Versions/A"
    codesign --force --sign "$IDENTITY" --timestamp=none --preserve-metadata=entitlements "$STAGED"
else
    echo "── codesign (adhoc, hardened runtime stripped)"
    codesign --force --sign - "$STAGED/Contents/Frameworks/llama.framework/Versions/A"
    codesign --force --sign - --preserve-metadata=entitlements "$STAGED"
fi
codesign --verify --deep --strict "$STAGED"

echo "── hdiutil"
hdiutil create -volname "Quenderin" -srcfolder "$BUILD/dmg-staging" -ov -format UDZO "$DMG" >/dev/null

echo "DONE: $DMG"
du -h "$DMG" | cut -f1
