#!/bin/bash
# Full Study mode suite on Simulator: Diff/Tab → WebView scroll → Feature (code+PDF) → CrossQA.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${SIM_UDID:-DB356EF5-941E-42D3-AC17-9B255BFBA6E1}"
BLANK="${STUDY_BLANK_V:-$HOME/Documents/Workspace/Engineer_Tex/.workspace/tmp/connects_blank.v}"
SPI="${STUDY_QA_CODE:-$HOME/Documents/Workspace/Gestalt-Lib-HS-SPI/Code/spi_master.v}"
MD="${STUDY_QA_MD:-$HOME/Documents/Workspace/Engineer_Tex/.workspace/tmp/study_webview_qa.md}"
PDF="${STUDY_QA_PDF:-}"
export SIM_UDID="$UDID"
export HARNESS_TIMEOUT_SEC="${HARNESS_TIMEOUT_SEC:-900}"

run() {
  echo ""
  echo "======== $* ========"
  "$ROOT/Scripts/run-sim-harness.sh" "$@"
}

run -DiffTabQA
run -StudyWebViewQA "-StudyQAMD=$MD"
if [[ -f "$BLANK" ]]; then
  run -StudyFeatureQA "-StudyQACode=$BLANK"
fi
if [[ -f "$SPI" ]]; then
  ARGS=(-StudyFeatureQA "-StudyQACode=$SPI")
  if [[ -n "$PDF" && -f "$PDF" ]]; then
    ARGS+=("-StudyQAPDF=$PDF")
  fi
  run "${ARGS[@]}"
fi
run -ScrollStressStudyFixture -CrossQAStress

echo ""
echo "======== Study suite finished ========"
