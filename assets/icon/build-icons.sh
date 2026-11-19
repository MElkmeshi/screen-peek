#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
tmp=$(mktemp -d)
swift make-icon.swift icon-1024.png 1024
set=$tmp/AppIcon.iconset
mkdir -p $set
for px in 16 32 128 256 512; do
  swift make-icon.swift $set/icon_${px}x${px}.png $px
  swift make-icon.swift $set/icon_${px}x${px}@2x.png $((px * 2))
done
iconutil -c icns $set -o AppIcon.icns
pngs=()
for px in 16 20 24 32 40 48 64 128 256; do
  swift make-icon.swift $tmp/win-$px.png $px --full-bleed
  pngs+=($tmp/win-$px.png)
done
magick "${pngs[@]}" ScreenPeek.ico
rm -rf $tmp
ls -lh AppIcon.icns ScreenPeek.ico icon-1024.png
