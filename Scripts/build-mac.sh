#!/bin/bash
# Build Connects for native Mac debugging (Mac Catalyst). No Simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-Connects-iPad}"
CONFIG="${CONFIG:-Debug}"
DERIVED="${DERIVED_DATA_PATH:-/tmp/Connects-mac-Derived}"

cd "$ROOT"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64,variant=Mac Catalyst' \
  -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="$DERIVED/Build/Products/${CONFIG}-maccatalyst/Connects.app"
echo ""
echo "Built (Mac Catalyst): $APP"
