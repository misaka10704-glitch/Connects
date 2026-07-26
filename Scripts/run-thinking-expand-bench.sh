#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Connects"
SIM_NAME="${SIM_NAME:-iPad mini (A17 Pro)}"
DERIVED="$(xcodebuild -scheme "$SCHEME" -destination "platform=iOS Simulator,name=$SIM_NAME" -showBuildSettings 2>/dev/null | awk -F' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')"
APP="$DERIVED/Connects.app"
BUNDLE_ID="com.misamisa.connects"

echo "== Build =="
xcodebuild -scheme "$SCHEME" -destination "platform=iOS Simulator,name=$SIM_NAME" -configuration Debug build | tail -3

echo "== Boot simulator =="
xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true

LOG="/tmp/connects-thinking-expand-bench.log"
rm -f "$LOG"
xcrun simctl spawn booted log stream --style compact --predicate 'eventMessage CONTAINS "ThinkingExpandBench" OR eventMessage CONTAINS "ConnectsScrollStress"' >"$LOG" &
LOG_PID=$!
sleep 1

echo "== Launch bench =="
xcrun simctl launch booted "$BUNDLE_ID" \
  -ThinkingExpandFixture \
  -ThinkingExpandTest

sleep 8
kill "$LOG_PID" 2>/dev/null || true

echo "== Bench output =="
grep -E 'ThinkingExpandBench|thinking-expand' "$LOG" || true
