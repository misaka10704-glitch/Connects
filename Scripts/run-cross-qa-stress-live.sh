#!/bin/bash
# Cross-QA stress with live Kimi API rounds in pure / study-portrait / study-landscape.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-sim-harness.sh" -ScrollStressStudyFixture -CrossQAStress -CrossQAStressLive -ScrollStressSlow "$@"
