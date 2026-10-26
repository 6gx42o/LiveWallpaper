#!/bin/bash
# Builds LiveWallpaper.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=LiveWallpaper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LiveWallpaper "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
