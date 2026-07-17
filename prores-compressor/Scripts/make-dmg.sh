#!/usr/bin/env bash
#
# Builds a Release ProRes Compressor.app and packages it into a shareable DMG.
#
# Two tiers:
#   • Personal (default): ad-hoc signed. Recipients right-click → Open the
#     first time to get past Gatekeeper's "unidentified developer".
#   • Distribution: set DEVELOPER_ID to a "Developer ID Application: …"
#     identity to sign with hardened runtime. Also set NOTARY_PROFILE (from
#     `xcrun notarytool store-credentials`) to notarize + staple the DMG so it
#     opens cleanly on any Mac.
#
# Usage:
#   ./Scripts/make-dmg.sh
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#     NOTARY_PROFILE=prc-notary ./Scripts/make-dmg.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."   # → prores-compressor/

APP_NAME="ProResCompressor"
SCHEME="ProResCompressor"
BUILD_DIR="build"
DMG_NAME="ProResCompressor.dmg"
VOL_NAME="ProRes Compressor"

command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen not found — install with: brew install xcodegen" >&2
    exit 1
}

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building Release"
rm -rf "$BUILD_DIR"
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_PATH" ] || {
    echo "error: build did not produce $APP_PATH" >&2
    exit 1
}

echo "==> Code signing"
if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "    Developer ID: $DEVELOPER_ID (hardened runtime)"
    codesign --force --deep --options runtime --timestamp \
        --sign "$DEVELOPER_ID" "$APP_PATH"
else
    echo "    Ad-hoc (personal use). Set DEVELOPER_ID to sign for distribution."
    codesign --force --deep --sign - "$APP_PATH"
fi

echo "==> Assembling DMG"
STAGING="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_NAME"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_NAME"
rm -rf "$STAGING"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_NAME"
    echo "    Notarized and stapled."
elif [ -n "${DEVELOPER_ID:-}" ]; then
    echo "note: signed but not notarized (set NOTARY_PROFILE to notarize)." >&2
fi

echo "==> Done: $DMG_NAME"
if [ -z "${DEVELOPER_ID:-}" ]; then
    echo "    Personal build — recipients: right-click the app → Open the first time."
fi
