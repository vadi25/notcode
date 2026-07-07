#!/bin/bash
# Builds NotCode.app (Release), ad-hoc signs it, and packages a DMG into dist/.
# Produces both NotCode-<version>.dmg and a versionless NotCode.dmg so the
# website can link a stable URL.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -m1 'CFBundleShortVersionString' project.yml | sed 's/.*"\(.*\)".*/\1/')
echo "==> Building NotCode $VERSION"

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen"; exit 1; }
xcodegen

xcodebuild -project NotCode.xcodeproj -scheme NotCode -configuration Release \
    -derivedDataPath build-release build

APP="build-release/Build/Products/Release/NotCode.app"
[ -d "$APP" ] || { echo "build product not found: $APP"; exit 1; }

# Ad-hoc signature (no Developer ID yet). Users get Gatekeeper's
# "Open Anyway" flow on first launch; see README.
codesign --force --deep -s - "$APP"

STAGE=$(mktemp -d)
mkdir -p dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp assets/dmg/background.png "$STAGE/.background/background.png"

# Build read-write first so Finder can lay out the window (background image,
# icon positions), then compress. Detach any stale mount from a failed run.
[ -d /Volumes/NotCode ] && hdiutil detach /Volumes/NotCode -quiet || true
RW="dist/NotCode-rw.dmg"
rm -f "$RW"
hdiutil create -volname "NotCode" -srcfolder "$STAGE" -ov -format UDRW "$RW" -quiet
hdiutil attach "$RW" -noverify -nobrowse

osascript <<'OSA'
tell application "Finder"
    tell disk "NotCode"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 104
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "NotCode.app" of container window to {165, 215}
        set position of item "Applications" of container window to {495, 215}
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA

# Volume icon must go on AFTER the Finder pass: Finder deletes
# .VolumeIcon.icns and clears the custom-icon flag while applying the layout.
cp NotCode/Resources/AppIcon.icns /Volumes/NotCode/.VolumeIcon.icns
SetFile -a C /Volumes/NotCode
sync
hdiutil detach /Volumes/NotCode -quiet

DMG="dist/NotCode-$VERSION.dmg"
rm -f "$DMG" dist/NotCode.dmg
hdiutil convert "$RW" -format UDZO -o "$DMG" -quiet
rm -f "$RW"
cp "$DMG" dist/NotCode.dmg
rm -rf "$STAGE"

echo "==> Done:"
ls -lh dist/
