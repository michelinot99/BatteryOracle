#!/bin/zsh
# Builds dist/BatteryOracle.app (ad-hoc signed). Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/BatteryOracle.app"
VERSION="$(git describe --tags --always 2>/dev/null || echo 1.0.0)"
VERSION="${VERSION#v}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/BatteryOracle"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BatteryOracle"
cp engine/forecast.py scripts/setup-engine.sh "$APP/Contents/Resources/"

if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BatteryOracle</string>
  <key>CFBundleDisplayName</key><string>BatteryOracle</string>
  <key>CFBundleIdentifier</key><string>io.github.michelinot99.BatteryOracle</string>
  <key>CFBundleExecutable</key><string>BatteryOracle</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Creato $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x BatteryOracle 2>/dev/null || true
  rm -rf /Applications/BatteryOracle.app
  cp -R "$APP" /Applications/
  open /Applications/BatteryOracle.app
  echo "Installato in /Applications"
fi
