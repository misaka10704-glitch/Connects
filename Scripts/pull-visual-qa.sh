#!/bin/bash
# Copy StudyVisualQA frames from the simulator app container to /tmp/connects_visual_qa.
# Usage:
#   SIM_UDID=... ./Scripts/pull-visual-qa.sh
set -euo pipefail

UDID="${SIM_UDID:-DB356EF5-941E-42D3-AC17-9B255BFBA6E1}"
BUNDLE_ID="com.misamisa.connects"
OUT="${VISUAL_QA_OUT:-/tmp/connects_visual_qa}"

DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
if [[ -z "$DATA" || ! -d "$DATA" ]]; then
  echo "FAIL: no app data container for $BUNDLE_ID on $UDID"
  exit 1
fi

SRC="$DATA/Documents/ConnectsVisualQA"
if [[ ! -d "$SRC" ]]; then
  echo "FAIL: missing $SRC — run -StudyVisualQA first"
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$SRC/." "$OUT/"
COUNT="$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')"
echo "==> Pulled $COUNT PNGs → $OUT"
find "$OUT" -name '*.png' | sort | head -80
