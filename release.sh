#!/bin/bash
# Builds a Developer ID signed, notarized and stapled dist/Telemic-<version>.dmg plus a signed
# Sparkle feed, dist/appcast.xml. Runs the same on a Mac and in CI (.github/workflows/release.yml).
#
# Needs:
#   1. A "Developer ID Application" certificate in a keychain on the search list
#      (security find-identity -v -p codesigning should list it).
#   2. Notary credentials, one of:
#        NOTARY_KEY_FILE + NOTARY_KEY_ID + NOTARY_ISSUER   App Store Connect API key (.p8), good for CI
#        NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM_ID  Apple ID with an app-specific password
#        NOTARY_PROFILE (default remotemic-notary)           saved with `xcrun notarytool store-credentials`
#   3. Sparkle's EdDSA update key, one of:
#        SPARKLE_KEY_FILE                                    exported with generate_keys -x
#        the login keychain, account "remotemic"             (default on the release Mac)
#      Its public half is SUPublicEDKey in App/Info.plist.
#
# The version comes from App/Info.plist (CI sets it from the release tag first).
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
fi
[ -n "$SIGN_ID" ] || { echo "No Developer ID Application identity found." >&2; exit 1; }
export SIGN_ID
echo "Signing as: $SIGN_ID"

if [ -n "${NOTARY_KEY_FILE:-}" ]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [ -n "${NOTARY_APPLE_ID:-}" ]; then
  NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
else
  NOTARY_AUTH=(--keychain-profile "${NOTARY_PROFILE:-remotemic-notary}")
fi
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  SPARKLE_AUTH=(--ed-key-file "$SPARKLE_KEY_FILE")
else
  SPARKLE_AUTH=(--account remotemic)
fi

./build-app.sh
codesign --verify --strict --deep build/Telemic.app
./test.sh

VERSION=$(plutil -extract CFBundleShortVersionString raw build/Telemic.app/Contents/Info.plist)
BUILD=$(plutil -extract CFBundleVersion raw build/Telemic.app/Contents/Info.plist)
DMG="dist/Telemic-$VERSION.dmg"
./make-dmg.sh

echo "Notarizing $DMG (usually a few minutes)…"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait --timeout 2h | tee build/notary.log
grep -q "status: Accepted" build/notary.log || {
  ID=$(sed -n 's/^ *id: //p' build/notary.log | head -1)
  [ -n "$ID" ] && xcrun notarytool log "$ID" "${NOTARY_AUTH[@]}" || true
  echo "Notarization failed." >&2; exit 1
}
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# Sparkle appcast for this release (served from the latest GitHub release).
SIG=$(Vendor/Sparkle/bin/sign_update "${SPARKLE_AUTH[@]}" "$DMG")
URL="https://github.com/alexkuang0/telemic/releases/download/v$VERSION/Telemic-$VERSION.dmg"
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Telemic</title>
    <item>
      <title>Telemic $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <link>https://github.com/alexkuang0/telemic/releases/tag/v$VERSION</link>
      <enclosure url="$URL" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
echo "Released $DMG and dist/appcast.xml"
