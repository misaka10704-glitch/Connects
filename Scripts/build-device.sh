#!/bin/bash
# Build Connects for a physical device (iPhone or iPad route). Same sources, iOS 12+.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTE="${1:-ipad}"
CONFIG="${2:-Debug}"
DERIVED="${DERIVED_DATA_PATH:-/tmp/Connects-${ROUTE}-Derived}"

case "$(echo "$ROUTE" | tr '[:upper:]' '[:lower:]')" in
  iphone|phone|1)
    SCHEME="Connects-iPhone"
    BUILD_CONFIG="${CONFIG}-iPhone"
    ;;
  ipad|pad|2)
    SCHEME="Connects-iPad"
    BUILD_CONFIG="$CONFIG"
    ;;
  *)
    echo "Usage: $0 [iphone|ipad] [Debug|Release]" >&2
    exit 1
    ;;
esac

cd "$ROOT"
xcodebuild \
  -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' \
  -configuration "$BUILD_CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="$DERIVED/Build/Products/${BUILD_CONFIG}-iphoneos/Connects.app"
echo ""
echo "Built: $APP"
echo "Scheme: $SCHEME  Configuration: $BUILD_CONFIG  MinimumOS: 12.0"
