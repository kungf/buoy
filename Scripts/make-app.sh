#!/bin/bash
# 打包 Buoy.app（LSUIElement 后台 agent 形态，bundle id com.wyang.buoy）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_DIR="build/Buoy.app"

swift build -c "$CONFIG" --product BuoyApp

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp ".build/$CONFIG/BuoyApp" "$APP_DIR/Contents/MacOS/Buoy"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Buoy</string>
    <key>CFBundleDisplayName</key><string>Buoy</string>
    <key>CFBundleIdentifier</key><string>com.wyang.buoy</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key><string>Buoy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "✅ $APP_DIR"
