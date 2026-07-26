#!/bin/bash
# Build Connects-iPad for Simulator and launch with harness args.
# Usage:
#   ./Scripts/run-sim-harness.sh -StudyHighlightQA
#   ./Scripts/run-sim-harness.sh -ScrollStressStudyFixture -ScrollStressStudy
#   ./Scripts/run-sim-harness.sh -UsageSimulation
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${SIM_UDID:-2EF57063-B52F-4CC8-8671-F1ECDD622290}"
BUNDLE_ID="com.misamisa.connects"
SCHEME="Connects-iPad"
TIMEOUT_SEC="${HARNESS_TIMEOUT_SEC:-600}"

if [[ -z "${CONNECTS_KIMI_API_KEY:-}" ]]; then
  SECRETS_PY="$ROOT/../Engineer_Tex/.workspace/scripts/anki_api_secrets.py"
  if [[ -f "$SECRETS_PY" ]]; then
    CONNECTS_KIMI_API_KEY="$(python3 -c "import sys; sys.path.insert(0, '$(dirname "$SECRETS_PY")'); from anki_api_secrets import get_kimi; print(get_kimi(), end='')")"
    export CONNECTS_KIMI_API_KEY
  fi
fi

cd "$ROOT"
echo "==> Building $SCHEME for simulator $UDID"
xcodebuild \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -quiet \
  build

APP="$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Connects-*/Build/Products/Debug-iphonesimulator/Connects.app | head -1)"
echo "==> App: $APP"

xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

LOG="/tmp/connects-sim-harness-$(date +%s).log"
echo "==> Log: $LOG"
echo "==> Launch args: $*"

# Stream logs while harness runs.
xcrun simctl spawn "$UDID" log stream --style compact --predicate 'process == "Connects"' >"$LOG" 2>&1 &
LOG_PID=$!
cleanup() { kill "$LOG_PID" 2>/dev/null || true; }
trap cleanup EXIT

xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" "$@" >"/tmp/connects-sim-console.log" 2>&1 &
APP_PID=$!

# Wait until process exits or timeout.
deadline=$((SECONDS + TIMEOUT_SEC))
while kill -0 "$APP_PID" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    echo "==> TIMEOUT ${TIMEOUT_SEC}s — terminating"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    kill "$APP_PID" 2>/dev/null || true
    break
  fi
  # Early exit if harness printed PASS/FAIL summary and exited.
  if grep -qE '\[ConnectsUsageSim\] (PASS|FAIL|done)|\[ConnectsScrollStress\].*(PASS|FAIL)|\[StudyFeatureQA\].*(PASS|FAIL)|exit=' "$LOG" 2>/dev/null; then
    sleep 2
    if ! pgrep -f 'Connects.app/Connects' >/dev/null 2>&1; then
      break
    fi
  fi
  sleep 2
done

wait "$APP_PID" 2>/dev/null || true
sleep 1

echo "==> Tail log"
grep -E '\[ConnectsUsageSim\]|\[ConnectsScrollStress\]|\[StudyFeatureQA\]|\[ConnectsRenderAudit\]|FAIL|PASS|NativeFormulaRenderer' "$LOG" | tail -80 || true
echo "==> Full log: $LOG"
