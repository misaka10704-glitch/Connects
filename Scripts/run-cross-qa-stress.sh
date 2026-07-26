#!/bin/bash
# Cross-QA long-context stress: pure AI + study portrait + study landscape scroll matrix,
# then 20-turn math-heavy pure chat scroll. Add -CrossQAStressLive for Kimi API rounds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-sim-harness.sh" -ScrollStressStudyFixture -CrossQAStress "$@"
