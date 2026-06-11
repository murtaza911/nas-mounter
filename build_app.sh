#!/bin/zsh
# Builds NASMounter.app from the SwiftPM package.
set -euo pipefail

cd "$(dirname "$0")"

echo "Building release binary..."
swift build -c release

APP="build/NAS Mounter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/NASMounter "$APP/Contents/MacOS/NASMounter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so Keychain access and SMAppService behave consistently.
codesign --force --deep --sign - "$APP"

echo ""
echo "Built: $PWD/$APP"
echo "Install with:  cp -R \"$APP\" /Applications/"
