#!/bin/bash
# Builds build/Telemic.app (universal) with the Telemic driver inside.
# Needs only the Command Line Tools. Signs ad hoc unless SIGN_ID is set.
set -euo pipefail
cd "$(dirname "$0")"

SIGN_ID="${SIGN_ID:--}"
OUT=build
APP="$OUT/Telemic.app"

./build.sh >/dev/null
./fetch-sparkle.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp App/Info.plist "$APP/Contents/Info.plist"
cp -R "$OUT/Telemic.driver" "$APP/Contents/Resources/Telemic.driver"
cp -R App/Resources/*.lproj "$APP/Contents/Resources/"
cp App/Resources/AppIcon.icns "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Frameworks"
cp -R Vendor/Sparkle/Sparkle.framework "$APP/Contents/Frameworks/"

SOURCES=(App/Sources/*.swift)
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$arch-apple-macos13.0" \
    -F Vendor/Sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$OUT/Telemic-$arch" "${SOURCES[@]}"
done
lipo -create -output "$APP/Contents/MacOS/Telemic" "$OUT/Telemic-arm64" "$OUT/Telemic-x86_64"
rm -f "$OUT/Telemic-arm64" "$OUT/Telemic-x86_64"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ "$SIGN_ID" = "-" ]; then
  for item in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force --sign - --timestamp=none "$item"
  done
  codesign --force --sign - --timestamp=none "$APP/Contents/Resources/Telemic.driver"
  codesign --force --sign - --timestamp=none "$APP"
else
  # Real identity: hardened runtime + secure timestamp, as notarization requires.
  # Sparkle's helpers first (inside out), as Sparkle's docs describe.
  for item in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force --sign "$SIGN_ID" --timestamp --options runtime "$item"
  done
  codesign --force --sign "$SIGN_ID" --timestamp --options runtime "$APP/Contents/Resources/Telemic.driver"
  codesign --force --sign "$SIGN_ID" --timestamp --options runtime --entitlements App/Telemic.entitlements "$APP"
fi

echo "Built $APP"
