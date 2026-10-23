#!/bin/bash
# Arma dist/Gajos.dmg: app universal (Apple Silicon + Intel), instrucciones e instalador de formatos extra.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0

APP=build/universal/Gajos.app
rm -rf build/universal
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Gajos" \
  .build/arm64-apple-macosx/release/Gajos \
  .build/x86_64-apple-macosx/release/Gajos
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

STAGE=build/dmg
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "dmg-extras/LEEME.txt" "$STAGE/"
cp "dmg-extras/Instalar formatos extra.command" "$STAGE/"
chmod +x "$STAGE/Instalar formatos extra.command"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
mkdir -p dist
OUT="dist/Gajos-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "Gajos" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
echo "Listo: $(pwd)/$OUT"
