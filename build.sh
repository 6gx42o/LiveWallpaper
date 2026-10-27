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
# CI passes VERSION (e.g. 1.42) so each release is newer than the last; local builds keep Info.plist's.
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
