#!/bin/bash
# 20-turn scroll stress with heavy real-analysis formulas (completeness theorems).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressFixture -ScrollStressMathHeavy -ScrollStressTest "$@"
