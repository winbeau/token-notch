#!/usr/bin/env bash
# 打发布产物：dist/TokenNotch-<版本>.dmg（拖进「应用程序」就能装）、同内容的 .zip、
# tokens 命令行、演示 MP4，以及 SHA256SUMS。上传到 GitHub release 用。
#
#   VERSION=0.3.2 ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
DMG="dist/TokenNotch-$VERSION.dmg"
ZIP="dist/TokenNotch-$VERSION.zip"
TOKENS="dist/tokens-$VERSION-macos-universal.zip"

VERSION="$VERSION" ./scripts/build-app.sh

rm -f "$DMG" "$ZIP" "$TOKENS"

# zip：ditto 保留签名和符号链接，也不会塞进 ._ 文件
ditto -c -k --keepParent dist/TokenNotch.app "$ZIP"
ditto -c -k dist/tokens "$TOKENS"

# dmg：应用 + 指向「应用程序」的替身，挂载后拖过去就是安装
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto dist/TokenNotch.app "$STAGE/TokenNotch.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Token Notch" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

cd dist
SUM_FILES=("${DMG#dist/}" "${ZIP#dist/}" "${TOKENS#dist/}")
[ -f token-notch-demo.mp4 ] && SUM_FILES+=(token-notch-demo.mp4)
shasum -a 256 "${SUM_FILES[@]}" > SHA256SUMS

echo
echo "产物（$VERSION）："
ls -lh "${SUM_FILES[@]}" SHA256SUMS | awk '{print "  " $9 "  " $5}'
