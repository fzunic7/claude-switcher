#!/usr/bin/env bash
# Builds dist/ClaudeSwitcher-<version>.dmg: the app plus an Applications shortcut to drag it onto.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="dist/Claude Switcher.app"
DMG="dist/ClaudeSwitcher-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Claude Switcher" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign -s - --force "$DMG"
echo "Built $DMG"
