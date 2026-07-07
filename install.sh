#!/bin/bash
# NotCode installer. Terminal downloads carry no quarantine flag, so this
# path never triggers Gatekeeper's "could not verify" prompt.
#
#   curl -fsSL https://notcode.rairai.xyz/install.sh | bash
#
set -euo pipefail

REPO="vadi25/notcode"
DMG_URL="https://github.com/$REPO/releases/latest/download/NotCode.dmg"

TMP=$(mktemp -d)
MOUNT=""
cleanup() {
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

[ "$(uname)" = "Darwin" ] || { echo "NotCode is a macOS app (13.0 or newer)."; exit 1; }

echo "Downloading NotCode (latest release)..."
curl -fL --progress-bar "$DMG_URL" -o "$TMP/NotCode.dmg"

echo "Installing to /Applications..."
MOUNT=$(hdiutil attach "$TMP/NotCode.dmg" -nobrowse -readonly | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
[ -d "$MOUNT/NotCode.app" ] || { echo "Unexpected DMG contents, aborting."; exit 1; }

osascript -e 'quit app "NotCode"' 2>/dev/null || true
rm -rf /Applications/NotCode.app
cp -R "$MOUNT/NotCode.app" /Applications/
hdiutil detach "$MOUNT" -quiet
MOUNT=""

# curl downloads have no quarantine attribute; clear any stale one anyway.
xattr -dr com.apple.quarantine /Applications/NotCode.app 2>/dev/null || true

open /Applications/NotCode.app
echo ""
echo "Done! NotCode is running: look for the bell in your menu bar."
echo "The setup guide will walk you through connecting WhatsApp."
