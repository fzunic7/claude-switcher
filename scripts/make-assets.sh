#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns and Resources/dmg-background.tiff from the drawings in Assets.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
"$(swift build --show-bin-path)/ClaudeSwitcher" --assets "$OUT"
iconutil -c icns "$OUT/AppIcon.iconset" -o Resources/AppIcon.icns
tiffutil -cathidpicheck "$OUT/dmg-background.png" "$OUT/dmg-background@2x.png" -out Resources/dmg-background.tiff
echo "Updated Resources/AppIcon.icns and Resources/dmg-background.tiff"
