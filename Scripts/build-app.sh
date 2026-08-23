#!/bin/zsh
# Builds Mr. AutoDuck with SwiftPM and wraps it into "build/Mr. AutoDuck.app".
#
#   Scripts/build-app.sh            # release build -> "build/Mr. AutoDuck.app"
#   Scripts/build-app.sh --run      # ...and (re)launch it
#   CONFIG=debug Scripts/build-app.sh
#   SIGN_IDENTITY="Apple Development: ..." Scripts/build-app.sh   # stable signature => mic permission survives rebuilds
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MrAutoDuck"                 # executable / process name
BUNDLE_NAME="Mr. AutoDuck"            # what Finder shows
BUNDLE_ID="${BUNDLE_ID:-com.mrautoduck.app}"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc
APP="build/${BUNDLE_NAME}.app"

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/${CONFIG}/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"
sed "s/__BUNDLE_ID__/${BUNDLE_ID}/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "Launched $BUNDLE_NAME (look for the duck in the menu bar)"
fi
