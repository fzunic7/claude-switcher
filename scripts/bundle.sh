#!/usr/bin/env bash
# Builds dist/Claude Switcher.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/Claude Switcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/ClaudeSwitcher" "$APP/Contents/MacOS/ClaudeSwitcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign -s - --force --deep "$APP"
echo "Built $APP"
