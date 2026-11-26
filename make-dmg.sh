#!/bin/bash
# Packages build/Telemic.app into dist/Telemic-<version>.dmg (drag to Applications).
# Unsigned unless SIGN_ID is set; notarize separately once a Developer ID is available.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Telemic.app
[ -d "$APP" ] || ./build-app.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
mkdir -p dist
DMG="dist/Telemic-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Telemic $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
if [ -n "${SIGN_ID:-}" ] && [ "$SIGN_ID" != "-" ]; then codesign --force --sign "$SIGN_ID" --timestamp "$DMG"; fi
echo "Built $DMG"
