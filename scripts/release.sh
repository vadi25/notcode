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
# Finder window layout (background, icon positions, view options), captured
# once from a Finder-arranged volume and committed. Regenerate by mounting a
# NotCode DMG read-write, arranging it in Finder, and copying its .DS_Store
# back to assets/dmg/. The volume name must stay "NotCode" or the background
# reference inside breaks.
cp assets/dmg/DS_Store "$STAGE/.DS_Store"
cp NotCode/Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# Brief read-write pass only to set the volume's custom-icon flag (it lives
# on the mounted volume root, not in any file). No Finder scripting — that
# needs an Automation permission and is flaky in CI/terminals.
[ -d /Volumes/NotCode ] && hdiutil detach /Volumes/NotCode -quiet || true
RW="dist/NotCode-rw.dmg"
rm -f "$RW"
hdiutil create -volname "NotCode" -srcfolder "$STAGE" -ov -format UDRW "$RW" -quiet
hdiutil attach "$RW" -noverify -nobrowse
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
