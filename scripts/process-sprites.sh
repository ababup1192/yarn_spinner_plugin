#!/usr/bin/env bash
# sprites/raw/<name>.* をニアレスト縮小して sprites/<name>.png を生成する。
# 設計解像度 480×300 (16:10) を前提:
#   bg_*.png    : 既に最終サイズの場合は raw/ にあれば 480x300 にニアレスト縮小して
#                 sprites/ にコピー。最終サイズで sprites/ に直接置いてある場合は処理不要
#   icon_*.{jpg,png}: 個別の最終サイズへ縮小 + 4 隅 floodfill で背景透過
#                     (典型: 24x24 final、ソースは大き目で OK)
# magick は devbox の imagemagick を期待。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$ROOT/sprites/raw"
OUT="$ROOT/sprites"

if ! command -v magick >/dev/null 2>&1; then
    echo "error: 'magick' not found in PATH. run inside devbox shell or install imagemagick." >&2
    exit 1
fi

# bg_*.png: raw/ に置かれていれば 480x300 にニアレスト縮小（透過は不要、design 16:10）。
# sprites/ に直接最終ファイルを置く運用も許容する（その場合は raw/ に何もなければスキップ）。
for src in "$RAW"/bg_*.png; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    dst="$OUT/$name"
    echo "  bg  $name (480x300, nearest)"
    magick "$src" -filter point -resize "480x300!" "$dst"
done

# 4 隅の色を「画像全体から色マッチで透過」してから縮小するヘルパ。
# floodfill (connected component) と違い、被写体の左右・内部に島になった同色ピクセル
# も拾える。AI 生成のアイコン (白背景 + 中央被写体) は被写体の影や凹凸で背景が分断
# されることが多いので、こちらが clean。
transparent_corners_and_resize() {
    local src=$1 dst=$2 W=$3 H=$4 fuzz=${5:-10}
    local SW SH TL TR BL BR
    SW=$(magick identify -format "%w" "$src")
    SH=$(magick identify -format "%h" "$src")
    TL=$(magick "$src" -format "%[pixel:p{0,0}]" info:)
    TR=$(magick "$src" -format "%[pixel:p{$((SW-1)),0}]" info:)
    BL=$(magick "$src" -format "%[pixel:p{0,$((SH-1))}]" info:)
    BR=$(magick "$src" -format "%[pixel:p{$((SW-1)),$((SH-1))}]" info:)
    magick "$src" \
        -alpha set \
        -fuzz "${fuzz}%" -transparent "$TL" \
        -fuzz "${fuzz}%" -transparent "$TR" \
        -fuzz "${fuzz}%" -transparent "$BL" \
        -fuzz "${fuzz}%" -transparent "$BR" \
        -filter point -resize "${W}x${H}!" \
        "$dst"
}

# icon_*.{jpg,png}: インベントリスロットアイコン。最終サイズ (design 上での占有 px)
# を明示指定する。4 隅の色を全画像から透過 (`-transparent`) して、被写体の左右・
# 内部に残る島も含めて背景を抜く。出力は常に PNG。
process_icon() {
    local stem=$1 W=$2 H=$3 fuzz=${4:-10}
    local src=""
    for ext in jpg jpeg png; do
        if [ -f "$RAW/${stem}.${ext}" ]; then
            src="$RAW/${stem}.${ext}"
            break
        fi
    done
    if [ -z "$src" ]; then
        echo "warn: $RAW/${stem}.{jpg,jpeg,png} not found, skip"
        return
    fi
    local dst="$OUT/${stem}.png"
    echo "  icon ${stem} (${W}x${H}, alpha+nearest, fuzz=${fuzz}%)"
    transparent_corners_and_resize "$src" "$dst" "$W" "$H" "$fuzz"
}

# 最終サイズは InventoryScene の slot 内アイコンサイズと一致させる (24x24)。
# JPEG 圧縮で白→被写体の境界に薄いグレー halo (190〜220) が残るため、それも抜ける
# fuzz 25% が必要。key 本体 (gray 168) との距離は 34% あるので 25% では誤って key を
# 抜くことはない。
process_icon "icon_demo_key" 24 24 25

echo "done."
