#!/bin/bash
# Cold open + mid-scroll width/study toggles at Air 1 ultra-slow pacing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressUltraSwitch -ScrollStressUltraSlow "$@"
