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

echo "── staging + hdiutil"
rm -rf "$BUILD/dmg-staging" "$DMG"
mkdir -p "$BUILD/dmg-staging"
cp -R "$APP" "$BUILD/dmg-staging/"
ln -s /Applications "$BUILD/dmg-staging/Applications"
hdiutil create -volname "Quenderin" -srcfolder "$BUILD/dmg-staging" -ov -format UDZO "$DMG" >/dev/null

echo "DONE: $DMG"
du -h "$DMG" | cut -f1
