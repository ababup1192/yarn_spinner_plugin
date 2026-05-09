#!/usr/bin/env bash
# sprites/raw/<name>.png をニアレスト縮小して sprites/<name>.png を生成する。
# 設計解像度 480×300 (16:10) を前提:
#   bg_*.png    : 960x600 -> 480x300（透過不要）
#   sprite_*.png: 個別の最終サイズへ 1/2 縮小 + 4 隅 floodfill で背景透過
#                 (AI 生成はソース 96×96 → 最終 48×48 のような 1/2 比率を期待)
#   char_*.png  : 1/4 縮小 + 4 隅 floodfill (旧 RPG キャラ用、Phase 4 で削除予定)
# magick は devbox の imagemagick を期待。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$ROOT/sprites/raw"
OUT="$ROOT/sprites"

if ! command -v magick >/dev/null 2>&1; then
    echo "error: 'magick' not found in PATH. run inside devbox shell or install imagemagick." >&2
    exit 1
fi

# bg_*.png: 960x600 -> 480x300（透過は不要、design 16:10 にフィット）
for src in "$RAW"/bg_*.png; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    dst="$OUT/$name"
    echo "  bg  $name (480x300, nearest)"
    magick "$src" -filter point -resize "480x300!" "$dst"
done

# 4 隅の色を「画像全体から色マッチで透過」してから縮小する共通ヘルパ。
# floodfill (connected component) ではなく `-transparent` (色マッチ全体) を使うのは、
# AI 生成画像の背景が分布したノイズを含むことが多く、connected 制限だと取りこぼすため。
# fuzz は呼び出し側から指定する (0=完全一致のみ、20=画像全体の差 20% まで許容)。
transparent_corners_and_resize() {
    local src=$1 dst=$2 W=$3 H=$4 fuzz=${5:-10}
    local SW SH TL TR BL BR
    SW=$(magick identify -format "%w" "$src")
    SH=$(magick identify -format "%h" "$src")
    TL=$(magick "$src" -format "%[pixel:p{0,0}]" info:)
    TR=$(magick "$src" -format "%[pixel:p{$((SW-1)),0}]" info:)
    BL=$(magick "$src" -format "%[pixel:p{0,$((SH-1))}]" info:)
    BR=$(magick "$src" -format "%[pixel:p{$((SW-1)),$((SH-1))}]" info:)
    # 4 つの corner 色をそれぞれ -transparent で抜く。順番に重ね適用。
    magick "$src" \
        -alpha set \
        -fuzz "${fuzz}%" -transparent "$TL" \
        -fuzz "${fuzz}%" -transparent "$TR" \
        -fuzz "${fuzz}%" -transparent "$BL" \
        -fuzz "${fuzz}%" -transparent "$BR" \
        -filter point -resize "${W}x${H}!" \
        "$dst"
}

# floodfill_corners_and_resize は後方互換のため残す (char_* 等が使う旧パターン)。
# 既存利用がなくなったら削除可能。
floodfill_corners_and_resize() {
    local src=$1 dst=$2 W=$3 H=$4 fuzz=${5:-20}
    local SW SH TL TR BL BR
    SW=$(magick identify -format "%w" "$src")
    SH=$(magick identify -format "%h" "$src")
    TL=$(magick "$src" -format "%[pixel:p{0,0}]" info:)
    TR=$(magick "$src" -format "%[pixel:p{$((SW-1)),0}]" info:)
    BL=$(magick "$src" -format "%[pixel:p{0,$((SH-1))}]" info:)
    BR=$(magick "$src" -format "%[pixel:p{$((SW-1)),$((SH-1))}]" info:)
    magick "$src" \
        -alpha set -fuzz "${fuzz}%" -fill none \
        -floodfill "+0+0" "$TL" \
        -floodfill "+$((SW-1))+0" "$TR" \
        -floodfill "+0+$((SH-1))" "$BL" \
        -floodfill "+$((SW-1))+$((SH-1))" "$BR" \
        -filter point -resize "${W}x${H}!" \
        "$dst"
}

# sprite_*.png: ホットスポット視覚用。AI 生成のソース解像度はバラつくので、
# 最終サイズ (design 解像度における占有 px) を明示的に指定する。
#
# 透過処理は 3 方式から選択する:
#   resize      : 透過処理なし、ニアレスト縮小だけ。ソースが既に切り抜き済み
#                 (alpha 付き or 単色背景許容) のとき。fuzz は無視。
#   floodfill   : 4 隅から色マッチ拡張 (connected component)。被写体が画像端に
#                 触れている場合 (door の wood が TR/BR コーナーまで広がる等) は
#                 こちらでないと被写体を保護できない。
#   transparent : 全画像から色マッチで透過。被写体が中央寄りで背景が分布的な
#                 ノイズを含む場合はこちらが clean。
#
# 理想的には AI 生成時に **chroma key 背景 (#ff00ff / #00ff00)** を指定すると
# fuzz 1〜3% で済み、どちらの方式でも被写体色とは衝突しない。
process_sprite() {
    local name=$1 W=$2 H=$3 fuzz=${4:-10} method=${5:-transparent}
    local src="$RAW/$name"
    local dst="$OUT/$name"
    [ -f "$src" ] || { echo "warn: $src not found, skip"; return; }
    echo "  sprite $name (${W}x${H}, method=${method}, fuzz=${fuzz}%)"
    case "$method" in
        resize)      magick "$src" -filter point -resize "${W}x${H}!" "$dst" ;;
        floodfill)   floodfill_corners_and_resize "$src" "$dst" "$W" "$H" "$fuzz" ;;
        transparent) transparent_corners_and_resize "$src" "$dst" "$W" "$H" "$fuzz" ;;
        *) echo "error: unknown method $method"; exit 1 ;;
    esac
}

# 最終サイズは RoomCatalog の HotspotDef#size と一致させる。
# 切り抜き済みソース (alpha 付き or 透過済み) は fuzz 無視で resize のみ。
process_sprite "sprite_drawer.png"  48  48   0   resize
process_sprite "sprite_door.png"    48  96   0   resize
process_sprite "sprite_note.png"    64  64   0   resize

# 旧 RPG キャラ。Phase 4 で削除予定。
process_char() {
    local name=$1 W=$2 H=$3
    local src="$RAW/$name"
    local dst="$OUT/$name"
    [ -f "$src" ] || { echo "warn: $src not found, skip"; return; }
    echo "  char $name (${W}x${H}, alpha+nearest)"
    floodfill_corners_and_resize "$src" "$dst" "$W" "$H"
}

process_char "char_ou.png"     96  160   # 384x640 -> 96x160
process_char "char_chest.png"  96  96    # 384x384 -> 96x96
process_char "char_gragon.png" 144 160   # 576x640 -> 144x160

echo "done."
