#!/bin/zsh
# Builds NASMounter.app from the SwiftPM package.
set -euo pipefail

cd "$(dirname "$0")"

echo "Building universal release binary (Apple silicon + Intel)..."
ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="build/NAS Mounter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/NASMounter" "$APP/Contents/MacOS/NASMounter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so Keychain access and SMAppService behave consistently.
codesign --force --deep --sign - "$APP"

echo ""
echo "Built: $PWD/$APP"
echo "Install with:  cp -R \"$APP\" /Applications/"
