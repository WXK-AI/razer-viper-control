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

# Flat colors — entire canvas is BG; macOS applies the squircle mask.
BG='#38383C'
BODY='#EEEDF2'
GREEN='#34C759'

magick -size ${SIZE}x${SIZE} "xc:${BG}" \
  -fill "$BODY" \
  -draw "roundrectangle 262,182 762,842 180,180" \
  -fill "$GREEN" \
  -draw "roundrectangle 412,312 612,368 18,18" \
  -fill "$BODY" \
  -draw "roundrectangle 282,430 318,500 8,8" \
  -draw "roundrectangle 282,540 318,610 8,8" \
  "$SRC"

for px in 16 32 64 128 256 512 1024; do
  magick "$SRC" -filter Lanczos -resize ${px}x${px} "$OUT_DIR/icon_${px}x${px}.png"
done

echo "Generated icon set in $OUT_DIR"
