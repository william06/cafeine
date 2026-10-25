#!/bin/bash
# Builds the menu bar app into build/Cafeine.app, icon included.
# Only needs the Command Line Tools (xcode-select --install), not Xcode.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Cafeine.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"

# Icon: draw the 1024 px PNG and turn it into an .icns with every size
swiftc -O app/icon.swift -o build/icon
build/icon build/icon.png >/dev/null
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size build/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) build/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14 \
  app/Cafeine.swift -o "$APP/Contents/MacOS/Cafeine"
codesign --force --sign - "$APP"
echo "Done: $APP"
echo "To put it in Applications: cp -R $APP /Applications/"
