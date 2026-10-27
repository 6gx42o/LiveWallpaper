#!/bin/bash
# Builds LiveWallpaper.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
APP=LiveWallpaper.app
# UNIVERSAL=1 (used for releases) builds for Apple silicon and Intel; needs Xcode rather than the Command Line Tools.
ARCHS=""
[ -n "${UNIVERSAL:-}" ] && ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/LiveWallpaper"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# CI passes VERSION (e.g. 1.42) so each release is newer than the last; local builds keep Info.plist's.
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
