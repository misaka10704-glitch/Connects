#!/bin/bash
# Ultra-slow chat scroll — Air 1 pacing with mid-scroll sampling.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressFixture -ScrollStressTest -ScrollStressUltraSlow "$@"
