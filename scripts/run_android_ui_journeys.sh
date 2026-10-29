#!/usr/bin/env bash
set -euo pipefail

# This script operates only the one ephemeral GitHub-hosted emulator, never a local phone.
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == Linux && "${GITHUB_REPOSITORY:-}" == alikatgh/quenderin ]]
serial=emulator-5554
adb -s "$serial" root
timeout 30 adb -s "$serial" wait-for-device

# No provider, reporting, model-download or other external app requests can leave this AVD.
# ADB's emulator transport is separate from the guest's IP network.
adb -s "$serial" shell iptables -P OUTPUT DROP
adb -s "$serial" shell ip6tables -P OUTPUT DROP
adb -s "$serial" shell svc wifi disable
adb -s "$serial" shell svc data disable
adb -s "$serial" shell iptables -S OUTPUT | grep -Fx -- '-P OUTPUT DROP'
adb -s "$serial" shell ip6tables -S OUTPUT | grep -Fx -- '-P OUTPUT DROP'
printf 'UI_NETWORK_BOUNDARY guest IPv4/IPv6 egress denied; no provider calls\n'

adb -s "$serial" install -r android/app/build/outputs/apk/debug/app-debug.apk
adb -s "$serial" install -r android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
printf 'UI_SOURCE_COMMIT %s\n' "$(git rev-parse HEAD)"

test_log="$RUNNER_TEMP/quenderin-ui-instrumentation.log"
set +e
timeout 600 adb -s "$serial" shell am instrument -w -r \
  -e class ai.quenderin.app.NativeJourneysTest,ai.quenderin.app.OnboardingRecoveryTest,ai.quenderin.app.ContentReportJourneyTest,ai.quenderin.app.BotHistoryJourneyTest \
  ai.quenderin.app.test/androidx.test.runner.AndroidJUnitRunner | tee "$test_log"
test_status=${PIPESTATUS[0]}
set -e

# Export bounded failure-state evidence too. No databases, credentials or arbitrary files.
python3 -B scripts/android_ui_screenshots.py export --serial "$serial" --require-complete
if [[ "$test_status" != 0 ]]; then
  exit "$test_status"
fi
python3 -B - "$test_log" <<'PY'
from pathlib import Path
import re
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
if not re.search(r"OK \(5 tests?\)", text) or "INSTRUMENTATION_CODE: -1" not in text:
    raise SystemExit("UI_JUNIT_FAILED: native instrumentation did not confirm all five tests passed")
if any(marker in text for marker in ("FAILURES!!!", "INSTRUMENTATION_FAILED", "Process crashed.", "shortMsg=")):
    raise SystemExit("UI_JUNIT_FAILED: instrumentation reported a failure")
print("UI_JUNIT_PASSED: 5 synthetic native tests; rendered PNG review remains separate")
PY
