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

DMG="dist/NotCode-$VERSION.dmg"
rm -f "$DMG" dist/NotCode.dmg
hdiutil create -volname "NotCode" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
cp "$DMG" dist/NotCode.dmg
rm -rf "$STAGE"

echo "==> Done:"
ls -lh dist/
