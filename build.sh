#!/bin/bash
# Builds the Telemic driver bundle and the telemic-feed test tool into ./build.
# Needs only the Command Line Tools. Signs ad hoc unless SIGN_ID is set
# (e.g. SIGN_ID="Developer ID Application: Your Name (TEAMID)").
set -euo pipefail
cd "$(dirname "$0")"

SIGN_ID="${SIGN_ID:--}"
OUT=build
DRV="$OUT/Telemic.driver"

rm -rf "$DRV"
mkdir -p "$DRV/Contents/MacOS" "$OUT"
cp Driver/Info.plist "$DRV/Contents/Info.plist"

clang -O2 -Wall -Wextra -std=c11 -arch arm64 -arch x86_64 \
  -mmacosx-version-min=13.0 -fvisibility=hidden -bundle \
  -framework CoreAudio -framework CoreFoundation \
  -o "$DRV/Contents/MacOS/Telemic" Driver/TelemicDriver.c

codesign --force --sign "$SIGN_ID" --timestamp=none "$DRV"

swiftc -O -o "$OUT/telemic-feed" Tools/telemic-feed/main.swift
codesign --force --sign "$SIGN_ID" --timestamp=none "$OUT/telemic-feed"

echo "Built $DRV and $OUT/telemic-feed"
