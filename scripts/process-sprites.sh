#!/usr/bin/env bash
# sprites/raw/<name>.png をニアレスト縮小して sprites/<name>.png を生成する。
# bg_*.png は 320x240 (1/2 縮小)、char_*.png は 1/4 縮小 + 4 隅 floodfill で背景透過。
# magick は devbox の imagemagick を期待。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$ROOT/sprites/raw"
OUT="$ROOT/sprites"

if ! command -v magick >/dev/null 2>&1; then
    echo "error: 'magick' not found in PATH. run inside devbox shell or install imagemagick." >&2
    exit 1
fi

# bg_*.png: 640x480 -> 320x240（透過は不要）
for src in "$RAW"/bg_*.png; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    dst="$OUT/$name"
    echo "  bg  $name (320x240, nearest)"
    magick "$src" -filter point -resize "320x240!" "$dst"
done

# キャラは「4 隅 floodfill で背景を透過 → ニアレスト縮小」。
# AI illustrations は背景がほぼ均一だが上下で色が違う場合もあるので、
# 4 隅から個別に floodfill して、それぞれの隅の色を抜く（fuzz 20% で多少のグラデも吸収）。
process_char() {
    local name=$1 W=$2 H=$3
    local src="$RAW/$name"
    local dst="$OUT/$name"
    [ -f "$src" ] || { echo "warn: $src not found, skip"; return; }
    local SW SH
    SW=$(magick identify -format "%w" "$src")
    SH=$(magick identify -format "%h" "$src")
    # 各隅のピクセル色を取得（floodfill のターゲット色）
    local TL TR BL BR
    TL=$(magick "$src" -format "%[pixel:p{0,0}]" info:)
    TR=$(magick "$src" -format "%[pixel:p{$((SW-1)),0}]" info:)
    BL=$(magick "$src" -format "%[pixel:p{0,$((SH-1))}]" info:)
    BR=$(magick "$src" -format "%[pixel:p{$((SW-1)),$((SH-1))}]" info:)
    echo "  char $name (${W}x${H}, alpha+nearest)"
    magick "$src" \
        -alpha set -fuzz 20% -fill none \
        -floodfill "+0+0" "$TL" \
        -floodfill "+$((SW-1))+0" "$TR" \
        -floodfill "+0+$((SH-1))" "$BL" \
        -floodfill "+$((SW-1))+$((SH-1))" "$BR" \
        -filter point -resize "${W}x${H}!" \
        "$dst"
}

process_char "char_ou.png"     96  160   # 384x640 -> 96x160
process_char "char_chest.png"  96  96    # 384x384 -> 96x96
process_char "char_gragon.png" 144 160   # 576x640 -> 144x160

echo "done."
