#!/bin/bash
# Builds a Developer ID signed, notarized and stapled dist/RemoteMic-<version>.dmg.
#
# One-time setup on the release Mac:
#   1. A "Developer ID Application" certificate in the login keychain
#      (security find-identity -v -p codesigning should list it).
#   2. Notary credentials stored in the keychain:
#        xcrun notarytool store-credentials remotemic-notary \
#          --apple-id <apple id> --team-id <TEAMID> --password <app-specific password>
#
#   3. Sparkle's EdDSA update key in the login keychain (account "remotemic"); its public half
#      is SUPublicEDKey in App/Info.plist. Back it up: Vendor/Sparkle/bin/generate_keys --account remotemic -x <file>
#
# Usage: ./release.sh            (picks the only Developer ID Application identity)
#        SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=remotemic-notary ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${NOTARY_PROFILE:-remotemic-notary}"
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
fi
[ -n "$SIGN_ID" ] || { echo "No Developer ID Application identity found." >&2; exit 1; }
export SIGN_ID
echo "Signing as: $SIGN_ID"

./build-app.sh
codesign --verify --strict --deep build/RemoteMic.app
./test.sh

VERSION=$(plutil -extract CFBundleShortVersionString raw build/RemoteMic.app/Contents/Info.plist)
DMG="dist/RemoteMic-$VERSION.dmg"
./make-dmg.sh

echo "Notarizing $DMG (usually a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
# Sparkle appcast for this release (served from the latest GitHub release).
BUILD=$(plutil -extract CFBundleVersion raw build/RemoteMic.app/Contents/Info.plist)
SIG=$(Vendor/Sparkle/bin/sign_update --account remotemic "$DMG")
URL="https://github.com/alexkuang0/RemoteMic/releases/download/v$VERSION/RemoteMic-$VERSION.dmg"
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>RemoteMic</title>
    <item>
      <title>RemoteMic $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <link>https://github.com/alexkuang0/RemoteMic/releases/tag/v$VERSION</link>
      <enclosure url="$URL" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
echo "Released $DMG and dist/appcast.xml"
echo "Publish with: gh release create v$VERSION $DMG dist/appcast.xml --title \"RemoteMic $VERSION\" --notes-file <notes>"
