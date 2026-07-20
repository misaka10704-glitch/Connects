#!/bin/bash
# Action chrome (复制/重跑/分叉): cold-open presence, settle shift, row clip — chat + study.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressActionChrome "$@"
