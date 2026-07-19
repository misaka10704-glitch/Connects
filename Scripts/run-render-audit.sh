#!/bin/bash
# Kimi K2.6 render + Study PDF audit on Mac (Catalyst). Uses API key from app Keychain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORPUS="${1:-$HOME/Downloads/connects-audit-corpus.json}"
DERIVED="${DERIVED_DATA_PATH:-/tmp/Connects-mac-Derived}"
CONFIG="${CONFIG:-Debug}"
LOG="/tmp/connects-render-audit-$(date +%s).log"

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

echo "==> Render audit (corpus: $CORPUS)"
echo "==> Log: $LOG"

log stream --style compact --predicate 'process == "Connects"' 2>/dev/null | tee "$LOG" &
LOG_PID=$!
sleep 1

set +e
"$BIN" -RenderAudit "$CORPUS"
EXIT=$?
set -e

sleep 2
kill "$LOG_PID" 2>/dev/null || true

grep '\[ConnectsRenderAudit\]' "$LOG" || true
echo "exit=$EXIT"
exit "$EXIT"
