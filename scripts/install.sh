#!/usr/bin/env bash
# 编译 release 版，装到「应用程序」，并打开「开机自启」（SMAppService 登录项）。
# 重复运行就是升级：先退出正在运行的实例，再替换 .app。
#
#   ./scripts/install.sh              # 装到 /Applications
#   ./scripts/install.sh --no-login   # 只装，不改开机自启
#   ./scripts/install.sh --uninstall  # 退出登录项、删掉安装好的 .app
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=TokenNotch.app
DEST="/Applications/$BUNDLE"
if [ ! -w /Applications ]; then
  DEST="$HOME/Applications/$BUNDLE"
  mkdir -p "$HOME/Applications"
  echo "（/Applications 不可写，改装到 $DEST）"
fi

# 只允许删掉这两个约定路径，避免变量出错时 rm -rf 跑到别处。
case "$DEST" in
  "/Applications/$BUNDLE" | "$HOME/Applications/$BUNDLE") ;;
  *) echo "意外的安装路径：$DEST" >&2; exit 1 ;;
esac

stop_running() {
  pkill -x TokenNotch 2>/dev/null || return 0
  for _ in $(seq 1 40); do
    pgrep -x TokenNotch >/dev/null || return 0
    sleep 0.1
  done
  echo "TokenNotch 没有自己退出，已强制结束" >&2
  pkill -9 -x TokenNotch 2>/dev/null || true
}

if [ "${1:-}" = "--uninstall" ]; then
  if [ -x "$DEST/Contents/MacOS/TokenNotch" ]; then
    "$DEST/Contents/MacOS/TokenNotch" --login-item off || true
  fi
  stop_running
  rm -rf "$DEST"
  echo "已删除 $DEST"
  exit 0
fi

./scripts/build-app.sh
stop_running
rm -rf "$DEST"
cp -R "dist/$BUNDLE" "$DEST"

open "$DEST"
if [ "${1:-}" != "--no-login" ]; then
  # 和右键菜单里的开关走同一条路（SMAppService.mainApp.register()）。
  # 先注销一次：之前可能从别的路径（比如 dist/）注册过，免得留下指向旧位置的记录。
  "$DEST/Contents/MacOS/TokenNotch" --login-item off >/dev/null 2>&1 || true
  if "$DEST/Contents/MacOS/TokenNotch" --login-item on; then
    echo "已开启开机自启"
  else
    echo "没能自动开启开机自启（原因见上）：在刘海面板上右键 →「开机自启」再试一次" >&2
  fi
fi
echo "已安装 $DEST"
