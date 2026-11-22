#!/usr/bin/env bash
# 用演示数据生成展示视频和截图：docs/images/demo.gif（英文）、demo-zh.gif、各页截图，dist/demo.mp4。
# 需要 ffmpeg。演示数据是虚构的（见 Sources/TokenCore/DemoData.swift），不读本机日志。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product TokenNotch
BIN="$(swift build --show-bin-path)/TokenNotch"
OUT="$(mktemp -d)/demo"
TOKEN_NOTCH_DEMO=1 TOKEN_NOTCH_DEMO_VIDEO="$OUT" "$BIN"

mkdir -p docs/images dist
for lang in en zh; do
  suffix=$([ "$lang" = en ] && echo "" || echo "-zh")
  ffmpeg -loglevel error -y -framerate 30 -i "$OUT/$lang/frames/%04d.jpg" \
    -vf "scale=1600:-2:flags=lanczos" -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart \
    "dist/demo$suffix.mp4"
  ffmpeg -loglevel error -y -i "dist/demo$suffix.mp4" \
    -vf "fps=20,scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    "docs/images/demo$suffix.gif"
  for shot in overview agent detail wings; do
    cp "$OUT/$lang/$shot.png" "docs/images/$shot$suffix.png"
  done
done
rm -rf "$(dirname "$OUT")"
ls -lh docs/images dist/demo*.mp4
