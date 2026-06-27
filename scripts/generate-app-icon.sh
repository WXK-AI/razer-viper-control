#!/bin/bash
# Generate a macOS app icon that matches the system squircle shape.
#
# macOS (unlike iOS) does NOT mask app icons — the shape must be baked into
# the asset. Apple's icon grid (Big Sur and later):
#   - 1024x1024 canvas
#   - 824x824 rounded body centered, leaving 100px gutter on all sides
#   - The corner is a CONTINUOUS-CURVATURE squircle (superellipse), not a
#     plain rounded rectangle. A simple rounded rect looks visibly wrong next
#     to real apps, so we generate a true superellipse mask here.
#   - Official drop shadow: 28px blur, +12px Y offset, black @ 50% opacity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/RazerMenuBarApp/Assets.xcassets/AppIcon.appiconset"
SRC="$ROOT/design/app-icon-source.png"
SIZE=1024

if ! command -v magick >/dev/null 2>&1; then
  echo "error: ImageMagick (magick) is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$ROOT/design"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Base artwork (full 1024 canvas). The squircle mask (step 3) clips it to the
# 824 body. Prefer the curated art at design/app-icon-art.png; otherwise fall
# back to a programmatic flat mouse so the script still works standalone.
ART_BASE="$ROOT/design/app-icon-art.png"
if [ -f "$ART_BASE" ]; then
  magick "$ART_BASE" -resize ${SIZE}x${SIZE}^ -gravity center -extent ${SIZE}x${SIZE} "$TMP/art.png"
else
  BODY='#EAE9EE'; GREEN='#34C759'; SIDE='#D0CED6'
  magick -size ${SIZE}x${SIZE} gradient:"#1A3028-#0D1A14" \
    \( -size ${SIZE}x${SIZE} xc:none -fill "$BODY"  -draw "roundrectangle 342,219 682,804 150,150" \) -composite \
    \( -size ${SIZE}x${SIZE} xc:none -fill "$GREEN" -draw "roundrectangle 447,350 577,408 22,22"    \) -composite \
    \( -size ${SIZE}x${SIZE} xc:none -fill "$SIDE"  -draw "roundrectangle 352,420 392,500 9,9"      \) -composite \
    \( -size ${SIZE}x${SIZE} xc:none -fill "$SIDE"  -draw "roundrectangle 352,530 392,610 9,9"      \) -composite \
    "$TMP/art.png"
fi

# 2) Generate a continuous-curvature squircle mask (superellipse, n=5).
#    824 body centered in 1024 -> half-size a=412, center 512.
python3 - "$TMP/mask.svg" <<'PY'
import sys, math
out = sys.argv[1]
SIZE, BODY, N, STEPS = 1024, 824, 5.0, 1440
cx = cy = SIZE / 2.0
a = BODY / 2.0
exp = 2.0 / N
pts = []
for i in range(STEPS):
    t = 2.0 * math.pi * i / STEPS
    ct, st = math.cos(t), math.sin(t)
    x = cx + math.copysign(a * (abs(ct) ** exp), ct)
    y = cy + math.copysign(a * (abs(st) ** exp), st)
    pts.append(f"{x:.3f},{y:.3f}")
path = "M " + " L ".join(pts) + " Z"
with open(out, "w") as f:
    f.write(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}">'
        f'<path d="{path}" fill="#ffffff"/></svg>'
    )
PY
magick -background none "$TMP/mask.svg" -resize ${SIZE}x${SIZE} "$TMP/mask.png"

# 3) Clip artwork to the squircle (transparent outside the body).
magick "$TMP/art.png" "$TMP/mask.png" \
  -alpha off -compose CopyOpacity -composite "$TMP/shaped.png"

# 4) Apply Apple's drop shadow: black, 50% opacity, 28px blur, +12px Y.
magick "$TMP/shaped.png" \
  \( +clone -background black -shadow 50x28+0+12 \) \
  +swap -background none -layers merge +repage \
  -gravity center -extent ${SIZE}x${SIZE} "$SRC"

# 5) Export all required sizes (default filter — Lanczos is slow on some hosts).
for px in 16 32 64 128 256 512 1024; do
  magick "$SRC" -resize ${px}x${px} "$OUT_DIR/icon_${px}x${px}.png"
done
magick "$SRC" -resize 128x128 "$ROOT/docs/icon.png"

echo "Generated squircle icon set in $OUT_DIR"
