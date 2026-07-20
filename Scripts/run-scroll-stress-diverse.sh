#!/bin/bash
# Full diverse suite: mixed chat → first-open → matrix (fast fling + ultra-slow per step).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressDiverse "$@"
