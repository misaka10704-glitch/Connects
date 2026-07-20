#!/bin/bash
# First-open QA-edge stress — cold open + micro scroll at user-bubble boundaries (Air 1 pacing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressFirstOpen -ScrollStressUltraSlow "$@"
