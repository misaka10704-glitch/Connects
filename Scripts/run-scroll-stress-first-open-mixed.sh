#!/bin/bash
# First-open QA-edge: alternate fast fling + ultra-slow micro scroll at bubble boundaries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressFirstOpen -ScrollStressMixedPacing "$@"
