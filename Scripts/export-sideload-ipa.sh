#!/bin/bash
# Export a sideloadable IPA for Sideloadly / AltStore / SideStore.
#
# Preferred artifact: development-signed IPA (keeps full entitlements —
# Study file bookmarks, keychain — sideload tools re-sign with the user's
# own Apple ID). Works on a free "Personal Team" — no paid account needed.
#
# Fallback: if -exportArchive fails (e.g. no provisioning), package an
# unsigned IPA from the archive — sideload tools can still sign it, but
# file-access entitlements may be stripped on device.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Connects-iPhone"
CONFIG="Release-iPhone"
ARCHIVE_PATH="${ARCHIVE_PATH:-/tmp/Connects-Sideload.xcarchive}"
DERIVED="${DERIVED_DATA_PATH:-/tmp/Connects-Sideload-Derived}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"

cd "$ROOT"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Connects/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Connects/Info.plist)
IPA_NAME="Connects-${VERSION}b${BUILD}.ipa"

echo "==> Archiving $SCHEME ($CONFIG)"
rm -rf "$ARCHIVE_PATH"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  archive

mkdir -p "$OUT_DIR"
EXPORT_DIR="$OUT_DIR/export-tmp"
rm -rf "$EXPORT_DIR" "$OUT_DIR/$IPA_NAME" "$OUT_DIR/Connects.ipa" "$OUT_DIR/Connects.ipa.sha256"

if xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist Scripts/ExportOptions-sideload.plist \
    -allowProvisioningUpdates; then
  SIGNED="yes"
else
  SIGNED="no"
  echo "==> -exportArchive failed; packaging unsigned IPA from archive"
  rm -rf "$EXPORT_DIR/Payload"
  mkdir -p "$EXPORT_DIR/Payload"
  cp -R "$ARCHIVE_PATH/Products/Applications/Connects.app" "$EXPORT_DIR/Payload/"
fi

echo "==> Packaging"
if [ "$SIGNED" = "yes" ]; then
  mv "$EXPORT_DIR/Connects.ipa" "$OUT_DIR/$IPA_NAME"
else
  (cd "$EXPORT_DIR" && ditto -c -k --sequesterRsrc Payload "$OUT_DIR/$IPA_NAME")
fi
rm -rf "$EXPORT_DIR"

cp "$OUT_DIR/$IPA_NAME" "$OUT_DIR/Connects.ipa"
shasum -a 256 "$OUT_DIR/$IPA_NAME" | sed "s|$OUT_DIR/$IPA_NAME|Connects.ipa|" > "$OUT_DIR/Connects.ipa.sha256"

echo ""
echo "IPA ready ($([ "$SIGNED" = yes ] && echo "development-signed" || echo "UNSIGNED — entitlements may be limited")):"
echo "  $OUT_DIR/$IPA_NAME"
echo "  $OUT_DIR/Connects.ipa        <- fixed name for 'latest' download link"
echo "  $OUT_DIR/Connects.ipa.sha256"
echo ""
echo "Upload both to a GitHub Release, e.g.:"
echo "  gh release create v$VERSION dist/Connects.ipa dist/Connects.ipa.sha256 --title \"$VERSION\""
echo "Stable URL once released:"
echo "  https://github.com/misaka10704-glitch/Connects/releases/latest/download/Connects.ipa"
