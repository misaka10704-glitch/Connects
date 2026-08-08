#!/bin/bash
# Archive Connects for App Store Connect / TestFlight upload.
# Requires Apple Distribution certificate on this Mac (Team C8XVZJLC2D).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Connects-iPhone"
CONFIG="Release-iPhone"
ARCHIVE_PATH="${ARCHIVE_PATH:-/tmp/Connects-TestFlight.xcarchive}"
DERIVED="${DERIVED_DATA_PATH:-/tmp/Connects-Archive-Derived}"

cd "$ROOT"
echo "Archiving $SCHEME ($CONFIG) → $ARCHIVE_PATH"
rm -rf "$ARCHIVE_PATH"

xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGNING_ALLOWED=YES \
  archive

echo ""
echo "Archive ready: $ARCHIVE_PATH"
echo "Next: open Xcode → Window → Organizer → Distribute App → App Store Connect"
echo "Or: Product → Archive in Xcode with scheme $SCHEME"
