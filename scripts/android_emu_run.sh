#!/usr/bin/env bash
# android_emu_run.sh — install the debug APK on the connected emulator/device, launch it, screenshot.
#
# Twin of scripts/ios_sim_run.sh (2026-09-05 tap-through). Builds only on request (--build: the native
# llama.cpp CMake step can take many minutes on first run); by default reuses app/build's debug APK.
# Does NOT drive taps (use `adb shell input tap X Y`) and does NOT download a model.
#
# Usage:
#   scripts/android_emu_run.sh [--build] [--mock] [--serial <adb-serial>] [--shot <out.png>]
#     --mock   launch with the debug-only extra quenderin.mock_ui=true (mock engine + mock downloader,
#              so onboarding → chat → settings → agent is walkable with no model file)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
PKG="ai.quenderin.app"
BUILD=0; MOCK=0; SERIAL="${ANDROID_SERIAL:-}"; SHOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build) BUILD=1 ;;
    --mock) MOCK=1 ;;
    --serial) SERIAL="$2"; shift ;;
    --shot) SHOT="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
ADB=(adb); [ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")
if [ "$BUILD" = 1 ]; then
  ( cd "$ROOT/android" && ./gradlew :app:assembleDebug --no-daemon -q 2>&1 | grep -E "^e: |FAILED|error:" ) || true
fi
[ -f "$APK" ] || { echo "no APK at $APK — run with --build" >&2; exit 1; }
"${ADB[@]}" wait-for-device
"${ADB[@]}" install -r -t "$APK" | tail -1
"${ADB[@]}" shell am force-stop "$PKG" >/dev/null 2>&1 || true
if [ "$MOCK" = 1 ]; then
  "${ADB[@]}" shell am start -n "$PKG/.MainActivity" --ez quenderin.mock_ui true | tail -1
else
  "${ADB[@]}" shell am start -n "$PKG/.MainActivity" | tail -1
fi
if [ -n "$SHOT" ]; then sleep 4; "${ADB[@]}" exec-out screencap -p > "$SHOT"; echo "screenshot: $SHOT"; fi
