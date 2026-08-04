#!/bin/bash
# Package TokenRunway.app - an LSUIElement background agent
# (bundle id com.wyang.tokenrunway).
#
# Signing modes (TRWY_SIGNING env):
#   adhoc     (default) ad-hoc signature; no certificate needed.
#             For local dev, CI, and screenshot generation.
#   identity  Developer ID signing with Hardened Runtime, for distribution.
#             Requires TRWY_SIGNING_IDENTITY, e.g.
#             "Developer ID Application: Your Name (TEAMID)".
#             Notarization + stapling are a separate step (Scripts/notarize.sh, TODO).
#
# Overridable: TRWY_VERSION, TRWY_BUILD, TRWY_SIGNING, TRWY_SIGNING_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_DIR="build/TokenRunway.app"
BUNDLE_ID="com.wyang.tokenrunway"
SIGNING_MODE="${TRWY_SIGNING:-adhoc}"
MARKETING_VERSION="${TRWY_VERSION:-0.1.0}"
BUILD_NUMBER="${TRWY_BUILD:-1}"

case "$SIGNING_MODE" in
  adhoc|identity) ;;
  *) echo "error: TRWY_SIGNING must be 'adhoc' or 'identity' (got: $SIGNING_MODE)" >&2; exit 1 ;;
esac

if [[ "$SIGNING_MODE" == "identity" ]]; then
  : "${TRWY_SIGNING_IDENTITY:?TRWY_SIGNING_IDENTITY is required for identity signing (e.g. \"Developer ID Application: Name (TEAMID)\")}"
fi

echo "› Building TokenRunwayApp ($CONFIG)…"
swift build -c "$CONFIG" --product TokenRunwayApp

echo "› Assembling .app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp ".build/$CONFIG/TokenRunwayApp" "$APP_DIR/Contents/MacOS/TokenRunway"
chmod +x "$APP_DIR/Contents/MacOS/TokenRunway"

# Copy bundled resources (provider logos, etc.) so Bundle.main can resolve them.
if [[ -d Sources/TokenRunwayApp/Resources ]]; then
  cp -R Sources/TokenRunwayApp/Resources/. "$APP_DIR/Contents/Resources/"
fi

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TokenRunway</string>
    <key>CFBundleDisplayName</key><string>TokenRunway</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleExecutable</key><string>TokenRunway</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- 自定义指标按设计访问内网 http:// Prometheus（prom.internal:9090 等）：
         ATS 默认拒绝明文，需放行。token 走明文 HTTP 为已知取舍（内网单用户工具）。 -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

# Strip extended attributes before signing: leftover ._ AppleDouble files or
# quarantine flags would otherwise break the signature.
xattr -cr "$APP_DIR"

echo "› Code signing ($SIGNING_MODE)…"
if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  codesign --force --sign - "$APP_DIR"
else
  ENT_FILE="$(mktemp -t trwy-entitlements)"
  trap 'rm -f "$ENT_FILE"' EXIT
  cat > "$ENT_FILE" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
ENT
  codesign --force --options runtime --timestamp --entitlements "$ENT_FILE" \
    --sign "$TRWY_SIGNING_IDENTITY" "$APP_DIR"
fi

echo "› Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/  /'

echo "✅ $APP_DIR (signed: $SIGNING_MODE)"
