#!/bin/bash
set -euo pipefail
if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then exit 0; fi
case "${CI_PRIMARY_REPOSITORY_PATH:-}" in
  /*) ;;
  *) echo "CI_PRIMARY_REPOSITORY_PATH must identify the absolute Quenderin checkout." >&2; exit 1 ;;
esac
if [ ! -d "$CI_PRIMARY_REPOSITORY_PATH" ]; then
  echo "CI_PRIMARY_REPOSITORY_PATH checkout is unavailable." >&2; exit 1
fi
ROOT="$(cd "$CI_PRIMARY_REPOSITORY_PATH" && pwd -P)"
for FILE in shared/prism-runtime.json shared/model-catalog.json scripts/verify_prism_apple_runtime.py apple/QuenderinKit/Package.swift apple/QuenderinApp/project.yml; do
  if [ ! -f "$ROOT/$FILE" ]; then
    echo "CI_PRIMARY_REPOSITORY_PATH is missing required Quenderin source: $FILE" >&2; exit 1
  fi
done
if [ "${CI_XCODEBUILD_EXIT_CODE:-1}" != "0" ]; then
  echo "Archive action failed; no runtime readiness claim." >&2
  exit 1
fi
: "${CI_APP_STORE_SIGNED_APP_PATH:?Xcode Cloud App Store signed export path is required}"
case "${CI_PRODUCT_PLATFORM:-}" in
  iOS) PLATFORM=ios ;;
  macOS) PLATFORM=macos ;;
  *) echo "Unsupported archive platform: ${CI_PRODUCT_PLATFORM:-missing}" >&2; exit 1 ;;
esac
# Xcode Cloud may create an ad-hoc intermediate archive, then apply managed
# distribution signing during export. Inspect the actual App Store payload.
python3 "$ROOT/scripts/verify_prism_apple_runtime.py" verify-distribution --distribution "$CI_APP_STORE_SIGNED_APP_PATH" --platform "$PLATFORM"
