#!/usr/bin/env bash
# 编译 release 并打包成 dist/TokenNotch.app（无 Dock 图标的菜单栏级应用），ad-hoc 签名。
set -euo pipefail
cd "$(dirname "$0")/.."

# 通用二进制（Apple 芯片 + Intel）
ARCH=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH[@]}" --product TokenNotch
swift build -c release "${ARCH[@]}" --product tokens
BIN="$(swift build -c release "${ARCH[@]}" --show-bin-path)"

APP=dist/TokenNotch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TokenNotch" "$APP/Contents/MacOS/TokenNotch"
cp "$BIN/tokens" dist/tokens
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 版本号：环境变量 VERSION，否则取最近的 v* 标签，都没有用 0.0.0
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
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
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "已生成 $APP（版本 $VERSION）和 dist/tokens"
