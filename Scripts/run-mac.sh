#!/bin/bash
# Build and run Connects natively on this Mac (Mac Catalyst).
# Usage:
#   ./Scripts/run-mac.sh
#   ./Scripts/run-mac.sh -ScrollStressFixture -ScrollStressTest
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Debug}"
DERIVED="${DERIVED_DATA_PATH:-/tmp/Connects-mac-Derived}"
LAUNCH_ARGS=("$@")

"$ROOT/Scripts/build-mac.sh"

APP="$DERIVED/Build/Products/${CONFIG}-maccatalyst/Connects.app"
BIN="$APP/Contents/MacOS/Connects"

if ((${#LAUNCH_ARGS[@]})); then
  echo "==> Launching with args: ${LAUNCH_ARGS[*]}"
  exec "$BIN" "${LAUNCH_ARGS[@]}"
else
  echo "==> Opening $APP"
  open "$APP"
fi
