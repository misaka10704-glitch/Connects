#!/bin/bash
# Ultra-slow orientation matrix: chat + study portrait/landscape, Air 1 pacing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressMatrix -ScrollStressUltraSlow "$@"
