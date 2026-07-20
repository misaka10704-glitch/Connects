#!/bin/bash
# Orientation matrix with fast+ultra mixed pacing per scroll step.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressMatrix -ScrollStressMixedPacing "$@"
