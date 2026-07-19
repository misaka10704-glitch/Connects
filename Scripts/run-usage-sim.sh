#!/bin/bash
# Full tool-coverage simulation on Mac: chat, thinking, search, Study PDF capture, image upload, fork, scroll.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-/tmp/Connects-mac-Derived}"
CONFIG="${CONFIG:-Debug}"
LOG="/tmp/connects-usage-sim-$(date +%s).log"

if [[ -z "${CONNECTS_KIMI_API_KEY:-}" ]]; then
  SECRETS_PY="$ROOT/../Engineer_Tex/.workspace/scripts/anki_api_secrets.py"
  if [[ -f "$SECRETS_PY" ]]; then
    CONNECTS_KIMI_API_KEY="$(python3 -c "import sys; sys.path.insert(0, '$(dirname "$SECRETS_PY")'); from anki_api_secrets import get_kimi; print(get_kimi(), end='')")"
    export CONNECTS_KIMI_API_KEY
  fi
fi

"$ROOT/Scripts/build-mac.sh"

APP="$DERIVED/Build/Products/${CONFIG}-maccatalyst/Connects.app"
BIN="$APP/Contents/MacOS/Connects"

echo "==> Usage simulation log: $LOG"
log stream --style compact --predicate 'process == "Connects"' 2>/dev/null | tee "$LOG" &
LOG_PID=$!
sleep 1

set +e
"$BIN" -UsageSimulation
EXIT=$?
set -e

sleep 2
kill "$LOG_PID" 2>/dev/null || true
grep -E '\[ConnectsUsageSim\]|NativeFormulaRenderer' "$LOG" || true
echo "exit=$EXIT"
exit "$EXIT"
