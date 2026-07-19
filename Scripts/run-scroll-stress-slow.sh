#!/bin/bash
# 20-turn scroll stress with iPad-like slow drag + chrome timing checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressFixture -ScrollStressTest -ScrollStressSlow "$@"
