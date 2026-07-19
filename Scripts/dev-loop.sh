#!/bin/bash
# Mac-native dev loop: build → launch scroll stress → read unified log.
# Does NOT use Simulator or a physical iOS device.
#
# Usage:
#   ./Scripts/dev-loop.sh
#   ./Scripts/dev-loop.sh --watch
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-/tmp/Connects-mac-Derived}"
CONFIG="${CONFIG:-Debug}"
BUNDLE_ID="com.misamisa.connects"
WATCH=false
STRESS_ARGS=(-ScrollStressFixture -ScrollStressTest)

if [[ "${1:-}" == "--watch" ]]; then
  WATCH=true
fi

run_once() {
  local stamp log app bin
  stamp="$(date '+%H:%M:%S')"
  echo ""
  echo "========== Connects dev-loop (Mac) @ $stamp =========="

  "$ROOT/Scripts/build-mac.sh"

  app="$DERIVED/Build/Products/${CONFIG}-maccatalyst/Connects.app"
  bin="$app/Contents/MacOS/Connects"

  log="$(mktemp /tmp/connects-mac-stress.XXXXXX.log)"
  echo "==> Launch scroll stress; logging 40s → $log"

  # Stream logs in background, then launch the binary with stress args.
  log stream --style compact --predicate "process == \"Connects\"" 2>/dev/null | tee "$log" &
  local log_pid=$!
  sleep 1
  "$bin" "${STRESS_ARGS[@]}" &
  local app_pid=$!
  sleep 40
  kill "$log_pid" 2>/dev/null || true
  kill "$app_pid" 2>/dev/null || true

  if grep -q '\[ConnectsScrollStress\] PASS' "$log"; then
    echo "SCROLL STRESS: PASS"
  elif grep -q '\[ConnectsScrollStress\] FAIL' "$log"; then
    echo "SCROLL STRESS: FAIL"
    grep '\[ConnectsScrollStress\]' "$log" || true
    return 1
  else
    echo "SCROLL STRESS: inconclusive (see $log)"
    grep '\[ConnectsScrollStress\]' "$log" || true
  fi

  if ls ~/Library/Logs/DiagnosticReports/Connects*.ips >/dev/null 2>&1; then
    local latest
    latest="$(ls -t ~/Library/Logs/DiagnosticReports/Connects*.ips | head -1)"
    local age_min=$(( ($(date +%s) - $(stat -f %m "$latest")) / 60 ))
    if (( age_min < 2 )); then
      echo "CRASH: $latest"
      return 1
    fi
  fi

  echo "dev-loop: OK"
  return 0
}

if $WATCH; then
  while true; do
    run_once || true
    sleep 60
  done
else
  run_once
fi
