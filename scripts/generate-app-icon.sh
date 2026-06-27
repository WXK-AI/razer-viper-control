#!/bin/bash
# Generate a full-bleed flat macOS app icon (no letterboxing, no black bars).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/RazerMenuBarApp/Assets.xcassets/AppIcon.appiconset"
SRC="$ROOT/design/app-icon-source.png"
SIZE=1024

if ! command -v magick >/dev/null 2>&1; then
  echo "error: ImageMagick (magick) is required" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$ROOT/design"

# macOS icon spec:
#   - 1024x1024 square, NO pre-rounded corners (macOS applies squircle ~200px radius)
#   - NO transparency; every pixel opaque
#   - Safe zone: keep content within ~80–944px (avoid outer 8%)
#   - Main element should fill 65–75% canvas height for visual weight
#   - Rich gradient background; flat single color looks unfinished
BODY='#EAE9EE'     # near-white mouse body
GREEN='#34C759'    # Apple system green – scroll wheel accent
SIDE='#D0CED6'     # slightly muted – side buttons

# Gradient background: dark forest green (top) to near-black (bottom)
magick -size ${SIZE}x${SIZE} gradient:"#1A3028-#0D1A14" /tmp/_icon_bg.png

# Mouse body: 432px wide × 730px tall, centered – fills ~71% of canvas height
# roundrectangle x1,y1 x2,y2 rx,ry
magick /tmp/_icon_bg.png \
  \( -size ${SIZE}x${SIZE} xc:none -fill "$BODY"  -draw "roundrectangle 296,147 728,877 190,190" \) -composite \
  \( -size ${SIZE}x${SIZE} xc:none -fill "$GREEN"  -draw "roundrectangle 432,310 592,380 24,24"  \) -composite \
  \( -size ${SIZE}x${SIZE} xc:none -fill "$SIDE"   -draw "roundrectangle 296,380 340,480 10,10"  \) -composite \
  \( -size ${SIZE}x${SIZE} xc:none -fill "$SIDE"   -draw "roundrectangle 296,510 340,610 10,10"  \) -composite \
  "$SRC"

rm -f /tmp/_icon_bg.png

for px in 16 32 64 128 256 512 1024; do
  magick "$SRC" -filter Lanczos -resize ${px}x${px} "$OUT_DIR/icon_${px}x${px}.png"
done

echo "Generated icon set in $OUT_DIR"
