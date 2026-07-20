#!/bin/bash
# Portrait/landscape matrix: pure chat + study PDF side panel, slow iPad pacing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressMatrix -ScrollStressSlow "$@"
