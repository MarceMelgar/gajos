#!/bin/bash
# Compila Gajos y arma build/Gajos.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Gajos.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Gajos "$APP/Contents/MacOS/Gajos"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Listo: $(pwd)/$APP"
