#!/bin/bash
# Builds, signs (Developer ID, hardened runtime, secure timestamp), notarizes and staples a release,
# then writes dist/ThingsRemindersSync-<version>.zip and its .sha256.
# Usage: VERSION=0.1.0 BUILD_NUMBER=1 scripts/release.sh
# Signing: SIGN_IDENTITY (a "Developer ID Application: ..." identity in your keychain).
# Notarization: an App Store Connect API key for the same team, given as NOTARY_KEY_FILE (.p8 path),
# NOTARY_KEY_ID and NOTARY_ISSUER_ID; without them, the KEYCHAIN_PROFILE notarytool profile.
# Run from a clean, committed tree; the tag should name the commit this builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:?Set VERSION, e.g. VERSION=0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
PROFILE="${KEYCHAIN_PROFILE:-notarytool-profile}"
SIGN_IDENTITY="${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity}"
APP="$ROOT/.build/ThingsRemindersSync.app"
DIST="$ROOT/dist"
ZIP="$DIST/ThingsRemindersSync-$VERSION.zip"

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "error: the working tree has uncommitted changes; release from a clean tree" >&2
  exit 1
fi

echo "Testing..."
swift test --package-path "$ROOT" >/dev/null

SIGN_IDENTITY="$SIGN_IDENTITY" VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" TIMESTAMP_FLAG="--timestamp" "$ROOT/scripts/build-app.sh" release
codesign --verify --strict --deep "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "error: not signed with Developer ID" >&2; exit 1; }

mkdir -p "$DIST"
SUBMIT="$(mktemp -d)/submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT"
echo "Notarizing (this takes a few minutes)..."
if [[ -n "${NOTARY_KEY_FILE:-}" ]]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_FILE}" "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required with NOTARY_KEY_FILE}"
  NOTARY_AUTH=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  NOTARY_AUTH=(--keychain-profile "$PROFILE")
fi
xcrun notarytool submit "$SUBMIT" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Release: $ZIP"
cat "$ZIP.sha256"
