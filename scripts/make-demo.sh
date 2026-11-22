#!/usr/bin/env bash
# 用演示数据生成展示素材：docs/images/demo.gif（英文）、demo-zh.gif、各页截图（JPEG），
# dist/demo.mp4，以及演示站的分享图 site/assets/og.jpg。桌面壁纸用 site/assets/wallpaper.webp。
# 需要 ffmpeg。演示数据是虚构的（见 Sources/TokenCore/DemoData.swift），不读本机日志。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product TokenNotch
BIN="$(swift build --show-bin-path)/TokenNotch"
TMP="$(mktemp -d)"
OUT="$TMP/demo"
TOKEN_NOTCH_DEMO=1 TOKEN_NOTCH_DEMO_VIDEO="$OUT" TOKEN_NOTCH_DEMO_WALLPAPER="$PWD/site/assets/wallpaper.webp" "$BIN"

mkdir -p docs/images dist
for lang in en zh; do
  suffix=$([ "$lang" = en ] && echo "" || echo "-zh")
  ffmpeg -loglevel error -y -framerate 30 -i "$OUT/$lang/frames/%04d.jpg" \
    -vf "scale=1600:-2:flags=lanczos" -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart \
    "dist/demo$suffix.mp4"
  # GIF 直接从逐帧图片生成（不经过 MP4，免得压缩噪点让静止的背景每帧都不一样）；
  # 用位置固定的有序抖动，背景不变的地方帧间差为零，照片背景也不会把体积撑大。
  # 画质拉满：原生 2 倍分辨率（2000px 宽，不缩放）、30fps、256 色，每个约 6~7MB
  ffmpeg -loglevel error -y -framerate 30 -i "$OUT/$lang/frames/%04d.jpg" \
    -vf "split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
    "docs/images/demo$suffix.gif"
  for shot in overview agent detail wings; do
    sips -s format jpeg -s formatOptions 86 -Z 1600 "$OUT/$lang/$shot.jpg" --out "docs/images/$shot$suffix.jpg" >/dev/null
  done
done
sips -s format jpeg -s formatOptions 82 -Z 1200 "$OUT/en/overview.jpg" --out site/assets/og.jpg >/dev/null
rm -rf "$TMP"
ls -lh docs/images dist/demo*.mp4 site/assets/og.jpg
