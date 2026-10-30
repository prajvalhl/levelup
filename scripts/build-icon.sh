#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Assets/LevelUp-Icon-Source.png"
OUTPUT_DIR="$ROOT/.build/generated-icon"
ICONSET="$OUTPUT_DIR/LevelUp.iconset"
VERIFY_ICONSET="$OUTPUT_DIR/verify-LevelUp.iconset"
OUTPUT="$OUTPUT_DIR/LevelUp.icns"

if [[ ! -f "$SOURCE" ]]; then
    echo "error: supplied LevelUp icon artwork is missing: $SOURCE" >&2
    exit 1
fi

DIMENSIONS="$(sips -g pixelWidth -g pixelHeight "$SOURCE" | awk '/pixelWidth:/ { width=$2 } /pixelHeight:/ { height=$2 } END { print width "x" height }')"
if [[ "${DIMENSIONS%%x*}" != "${DIMENSIONS##*x}" ]]; then
    echo "error: expected square icon artwork to preserve its proportions; got $DIMENSIONS" >&2
    exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

make_icon() {
    local pixels="$1"
    local filename="$2"
    sips --resampleHeightWidth "$pixels" "$pixels" "$SOURCE" --out "$ICONSET/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
cp "$ICONSET/icon_16x16@2x.png" "$ICONSET/icon_32x32.png"
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
cp "$ICONSET/icon_128x128@2x.png" "$ICONSET/icon_256x256.png"
make_icon 512 icon_256x256@2x.png
cp "$ICONSET/icon_256x256@2x.png" "$ICONSET/icon_512x512.png"
make_icon 1024 icon_512x512@2x.png

rm -f "$OUTPUT"
rm -rf "$VERIFY_ICONSET"
iconutil --convert icns --output "$OUTPUT" "$ICONSET"
iconutil --convert iconset --output "$VERIFY_ICONSET" "$OUTPUT"

for entry in \
    'icon_16x16.png:16' \
    'icon_16x16@2x.png:32' \
    'icon_32x32.png:32' \
    'icon_32x32@2x.png:64' \
    'icon_128x128.png:128' \
    'icon_128x128@2x.png:256' \
    'icon_256x256.png:256' \
    'icon_256x256@2x.png:512' \
    'icon_512x512.png:512' \
    'icon_512x512@2x.png:1024'; do
    filename="${entry%%:*}"
    pixels="${entry##*:}"
    image="$VERIFY_ICONSET/$filename"
    if [[ ! -s "$image" ]]; then
        echo "error: generated ICNS is missing representation $filename" >&2
        exit 1
    fi
    image_dimensions="$(sips -g pixelWidth -g pixelHeight "$image" | awk '/pixelWidth:/ { width=$2 } /pixelHeight:/ { height=$2 } END { print width "x" height }')"
    if [[ "$image_dimensions" != "${pixels}x${pixels}" ]]; then
        echo "error: generated $filename has unexpected dimensions $image_dimensions" >&2
        exit 1
    fi
done

echo "Generated $OUTPUT from $SOURCE ($DIMENSIONS, aspect ratio preserved)"
