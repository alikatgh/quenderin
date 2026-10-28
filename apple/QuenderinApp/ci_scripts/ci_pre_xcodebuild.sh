#!/bin/bash
set -euo pipefail
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
if [ "${CI:-}" != "TRUE" ] || [ "${CI_XCODE_CLOUD:-}" != "TRUE" ] || [ "${QUENDERIN_RUNTIME:-}" != "prism" ] || [ -n "${QUENDERIN_LLAMA_DIR:-}" ]; then
  echo "Cloud requires the explicit verified Prism release profile." >&2
  exit 1
fi
test "$(cat "$ROOT/apple/QuenderinKit/.quenderin-prism-release")" = prism
python3 -B "$ROOT/scripts/verify_prism_apple_runtime.py" verify-release
