#!/usr/bin/env bash
# Builds dist/ClaudeSwitcher-<version>.dmg: a drag-to-Applications window with the app icon,
# an Applications shortcut and an arrow background.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="dist/Claude Switcher.app"
DMG="dist/ClaudeSwitcher-$VERSION.dmg"
VOL="Claude Switcher"
WORK=$(mktemp -d)
MOUNT=""
cleanup() { [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force || true; rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/stage/.background"
cp -R "$APP" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
cp Resources/dmg-background.tiff "$WORK/stage/.background/background.tiff"

hdiutil create -volname "$VOL" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk -F'\t' '/\/Volumes\// {print $NF}')

# Lay out the Finder window. Needs permission to control Finder; without it the DMG still works, just plain.
if ! osascript <<OSA
tell application "Finder"
  tell disk "$(basename "$MOUNT")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Claude Switcher.app" of container window to {165, 215}
    set position of item "Applications" of container window to {495, 215}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
then
  echo "warning: couldn't arrange the DMG window (Finder automation not allowed); the DMG is plain" >&2
fi

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
codesign -s - --force "$DMG"
echo "Built $DMG"
