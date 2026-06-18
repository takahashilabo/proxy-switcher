#!/bin/bash
#
# Build ProxySwitcher.app — a menu-bar-only macOS agent.
#
# Usage:  ./build_app.sh
# Output: ./ProxySwitcher.app   (drag it into /Applications)
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ProxySwitcher"
BUNDLE_ID="com.ktakahas.ProxySwitcher"
VERSION="1.0"
APP_DIR="${APP_NAME}.app"

echo "==> Building release binary…"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "==> Assembling ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>Proxy Switcher</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSLocationUsageDescription</key>
    <string>Proxy Switcher reads the current Wi-Fi network name to choose the right proxy setting.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Proxy Switcher reads the current Wi-Fi network name to choose the right proxy setting.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS gives the app a stable identity for Location /
# Login Item permissions. Replace "-" with your Developer ID to distribute.
echo "==> Code signing (ad-hoc)…"
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo ""
echo "Done -> ${APP_DIR}"
echo "Install:  mv \"${APP_DIR}\" /Applications/ && open /Applications/${APP_DIR}"
