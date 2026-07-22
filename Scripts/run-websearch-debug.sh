#!/bin/bash
# Focused Mac web-search quality debug on Kimi K2.6.
# Usage:
#   ./Scripts/run-websearch-debug.sh
#   ./Scripts/run-websearch-debug.sh nobel-physics-2024,anime-culture-history
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-/tmp/Connects-mac-Derived}"
CONFIG="${CONFIG:-Debug}"
STAMP="$(date +%s)"
LOG="/tmp/connects-websearch-debug-${STAMP}.log"
CASE_FILTER="${1:-${CONNECTS_WEBSEARCH_CASES:-}}"

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

ARGS=(-WebSearchDebug)
if [[ -n "$CASE_FILTER" ]]; then
  ARGS+=(-WebSearchDebugCase "$CASE_FILTER")
  echo "==> Case filter: $CASE_FILTER"
fi

echo "==> Binary mtime: $(stat -f '%Sm' "$BIN")"
echo "==> WebSearch debug log: $LOG"
# Capture app stdout/stderr (harness prints) + unified log.
log stream --style compact --predicate 'process == "Connects"' >>"$LOG" 2>/dev/null &
LOG_PID=$!
sleep 1

set +e
# unbuffered-ish line output for harness markers
"$BIN" "${ARGS[@]}" >>"$LOG" 2>&1
EXIT=$?
set -e

sleep 2
kill "$LOG_PID" 2>/dev/null || true
echo "---- harness summary ----"
rg -n '\[ConnectsWebSearchDebug\] (begin|send |case |PASS|FAIL)|\[Connects\] web search' "$LOG" || true
echo "report=~/Downloads/connects-websearch-debug-report.json"
echo "exit=$EXIT"
exit "$EXIT"
