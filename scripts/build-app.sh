#!/usr/bin/env bash
# 编译 release 并打包成 dist/TokenNotch.app（无 Dock 图标的菜单栏级应用），ad-hoc 签名。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TokenNotch
swift build -c release --product tokens
BIN="$(swift build -c release --show-bin-path)"

APP=dist/TokenNotch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TokenNotch" "$APP/Contents/MacOS/TokenNotch"
cp "$BIN/tokens" dist/tokens

VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Token Notch</string>
  <key>CFBundleDisplayName</key><string>Token Notch</string>
  <key>CFBundleIdentifier</key><string>dev.token-notch.app</string>
  <key>CFBundleExecutable</key><string>TokenNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "已生成 $APP 和 dist/tokens"
