#!/bin/bash
# Downloads the pinned Sparkle release into Vendor/Sparkle (git-ignored) and checks its hash.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
DEST=Vendor/Sparkle

[ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ] && exit 0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
echo "$SHA256  $TMP/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
mkdir -p "$TMP/x"
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP/x"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$TMP/x/Sparkle.framework" "$DEST/"
cp -R "$TMP/x/bin" "$DEST/"
cp "$TMP/x/LICENSE" "$DEST/LICENSE"
# RemoteMic isn't sandboxed, so Sparkle's XPC services aren't needed (Sparkle docs: optional).
rm -rf "$DEST/Sparkle.framework/Versions/B/XPCServices" "$DEST/Sparkle.framework/XPCServices"
echo "$VERSION" > "$DEST/.version"
echo "Sparkle $VERSION ready in $DEST"
