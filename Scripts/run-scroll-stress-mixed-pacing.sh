#!/bin/bash
# Mixed fast fling + ultra-slow steps — catches fling bugs and mid-scroll jank.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressFixture -ScrollStressMathHeavy -ScrollStressTest -ScrollStressMixedPacing "$@"
