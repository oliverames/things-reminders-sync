#!/bin/bash
# Builds Things Reminders Sync with SwiftPM and assembles a signed .app bundle.
# Usage: scripts/build-app.sh [debug|release]
# Signs with the Developer ID identity and the hardened runtime. The app holds no Reminders permission:
# Reminders access goes through RemCTL (its Capability Host holds the grant).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP_NAME="ThingsRemindersSync"
BUNDLE_ID="${BUNDLE_ID:-com.oliverames.ThingsRemindersSync}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# Set SIGN_IDENTITY to your own "Developer ID Application: ..." identity; without one the app is signed ad hoc.
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Oliver Ames (PV3W52NDZ3)}"
APP_DIR="$ROOT/.build/$APP_NAME.app"

echo "Building ($CONFIG)..."
swift build --package-path "$ROOT" -c "$CONFIG"
BUILD_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"

echo "Assembling $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
for resource in "$BUILD_DIR"/*.bundle; do
  [[ -e "$resource" ]] || continue
  cp -R "$resource" "$APP_DIR/Contents/Resources/"
done

sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  "$ROOT/Resources/Info.plist" > "$APP_DIR/Contents/Info.plist"
plutil -lint "$APP_DIR/Contents/Info.plist"

# Icon: draw an iconset with scripts/make-icon.swift, then convert. Skipped (with a warning) if it fails.
ICON_TMP="$(mktemp -d)"
if swift "$ROOT/scripts/make-icon.swift" "$ICON_TMP/AppIcon.iconset" \
   && iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"; then
  :
else
  echo "warning: icon generation failed; building without an icon" >&2
fi
rm -rf "$ICON_TMP"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime "${TIMESTAMP_FLAG:---timestamp=none}" \
    --entitlements "$ROOT/Resources/ThingsRemindersSync.entitlements" \
    --sign "$IDENTITY" "$APP_DIR"
else
  echo "warning: '$IDENTITY' not found; signing ad hoc." >&2
  codesign --force --options runtime \
    --entitlements "$ROOT/Resources/ThingsRemindersSync.entitlements" \
    --sign - "$APP_DIR"
fi

echo "Built: $APP_DIR"
