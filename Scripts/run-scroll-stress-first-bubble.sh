#!/bin/bash
# Study-landscape: scroll until first user bubble at top edge; detect viewport snap into assistant body.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressFirstBubble -ScrollStressTest "$@"
