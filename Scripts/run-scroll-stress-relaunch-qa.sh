#!/bin/bash
# Multi-conversation cold opens + first QA-edge micro-jitter (chat/study × portrait/landscape).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressRelaunchQA "$@"
