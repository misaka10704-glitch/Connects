#!/bin/bash
# Ultra-slow study narrow panel — Air 1 pacing with mid-scroll blank/clip checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressStudy -ScrollStressUltraSlow "$@"
