#!/bin/zsh
# icon-1024.png → AppIcon.icns (all sizes). Draws the PNG with make-icon.swift first.
set -e
cd "$(dirname "$0")"
swift make-icon.swift icon-1024.png
SET=$(mktemp -d)/AppIcon.iconset; mkdir -p $SET
for s in 16 32 128 256 512; do sips -z $s $s icon-1024.png --out $SET/icon_${s}x${s}.png >/dev/null; sips -z $((s*2)) $((s*2)) icon-1024.png --out $SET/icon_${s}x${s}@2x.png >/dev/null; done
iconutil -c icns $SET -o AppIcon.icns
