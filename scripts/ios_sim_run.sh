#!/usr/bin/env bash
# ios_sim_run.sh — build the Quenderin iOS app, install it on a simulator, launch it, screenshot.
#
# Built for the 2026-09-05 first-run tap-through, where the same five-step chain (xcodegen →
# xcodebuild → simctl install → simctl launch → simctl screenshot) was retyped five times. What it
# catches that `swift test` cannot: the APP TARGET failing to compile (iOS-SDK-only actor isolation,
# `canImport(UIKit)` branches) and anything only visible on screen. It does NOT drive taps — use the
# simulator MCP / `xcrun simctl` for gestures — and it does NOT download a model.
#
# Usage:
#   scripts/ios_sim_run.sh [--mock] [--udid <UDID>] [--no-build] [--shot <out.png>]
#     --mock      launch with QUENDERIN_MOCK_UI=1 (DEBUG-only: mock engine + mock downloader, so
#                 onboarding → chat → settings → agent is walkable with no model file)
#     --udid      simulator to use (default: $QUENDERIN_SIM_UDID, else the first booted iPhone)
#     --no-build  skip xcodegen/xcodebuild, reuse the last build
#     --shot      write a screenshot here ~3 s after launch
# Env: QUENDERIN_DERIVED_DATA (default /tmp/quenderin-dd) keeps the build out of the repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/apple/QuenderinApp"
DD="${QUENDERIN_DERIVED_DATA:-/tmp/quenderin-dd}"
BUNDLE="ai.quenderin.Quenderin"
MOCK=0; BUILD=1; UDID="${QUENDERIN_SIM_UDID:-}"; SHOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mock) MOCK=1 ;;
    --no-build) BUILD=0 ;;
    --udid) UDID="$2"; shift ;;
    --shot) SHOT="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl list devices booted | grep -o '[0-9A-F-]\{36\}' | head -1 || true)"
  [ -n "$UDID" ] || { echo "no booted simulator — pass --udid or boot one (xcrun simctl boot <udid>)" >&2; exit 1; }
fi
if [ "$BUILD" = 1 ]; then
  ( cd "$APP_DIR" && xcodegen generate >/dev/null )
  LOG="$DD/build.log"; mkdir -p "$DD"
  if ! ( cd "$APP_DIR" && xcodebuild -project Quenderin.xcodeproj -scheme Quenderin -configuration Debug \
        -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build >"$LOG" 2>&1 ); then
    echo "BUILD FAILED — first errors:" >&2; grep -E "error:" "$LOG" | sort -u | head -20 >&2; exit 1
  fi
  echo "built ($(grep -c 'warning:' "$LOG" || true) warnings)"
fi
APP="$DD/Build/Products/Debug-iphonesimulator/Quenderin.app"
[ -d "$APP" ] || { echo "no app at $APP — run without --no-build" >&2; exit 1; }
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
if [ "$MOCK" = 1 ]; then
  SIMCTL_CHILD_QUENDERIN_MOCK_UI=1 xcrun simctl launch "$UDID" "$BUNDLE"
else
  xcrun simctl launch "$UDID" "$BUNDLE"
fi
if [ -n "$SHOT" ]; then sleep 3; xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null; echo "screenshot: $SHOT"; fi
