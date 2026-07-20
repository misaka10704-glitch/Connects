#!/bin/bash
# History reading: oscillate near assistant bubble after first QA edge — detect viewport snap.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressBubbleWiggle -ScrollStressTest "$@"
