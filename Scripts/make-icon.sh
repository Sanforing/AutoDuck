#!/bin/zsh
# Renders the app icon (Scripts/render-appicon.swift) and packs it into Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swift Scripts/render-appicon.swift "$TMP/icon_1024.png" >/dev/null
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$TMP/icon_1024.png" Resources/AppIcon-1024.png
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns and Resources/AppIcon-1024.png"
