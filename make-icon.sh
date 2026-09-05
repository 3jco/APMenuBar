#!/bin/bash
# Turn any PNG into Resources/AppIcon.icns.
#   ./make-icon.sh ~/Desktop/whatever.png
#
# Handles the two things that bite: an opaque background (flood-filled away from
# the edges, so enclosed pale areas survive) and non-square art (padded, never
# squashed — sips -z would distort it).
set -euo pipefail
cd "$(dirname "$0")"
SRC="${1:?usage: ./make-icon.sh <source.png>}"

python3 - "$SRC" <<'PY'
import sys
from collections import deque
from PIL import Image

img = Image.open(sys.argv[1]).convert("RGBA")
w, h = img.size
px = img.load()

seed = px[0, 0][:3]
TOL = 45
def near(c):
    return sum((a - b) ** 2 for a, b in zip(c[:3], seed)) <= TOL * TOL

# Only strip if the corner is actually opaque background.
if px[0, 0][3] == 255:
    seen = [[False] * w for _ in range(h)]
    queue = deque()
    for x in range(w):
        for y in (0, h - 1):
            if near(px[x, y]): queue.append((x, y)); seen[y][x] = True
    for y in range(h):
        for x in (0, w - 1):
            if near(px[x, y]) and not seen[y][x]: queue.append((x, y)); seen[y][x] = True
    cleared = 0
    while queue:
        x, y = queue.popleft()
        r, g, b, _ = px[x, y]
        px[x, y] = (r, g, b, 0)
        cleared += 1
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and near(px[nx, ny]):
                seen[ny][nx] = True
                queue.append((nx, ny))
    print(f"  background: cleared {100 * cleared / (w * h):.1f}%")
else:
    print("  background: already transparent")

img = img.crop(img.getbbox())
side = int(max(img.size) * 1.10)          # ~5% breathing room each side
canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2), img)
canvas.resize((1024, 1024), Image.LANCZOS).save("Resources/AppIcon-source.png")
print(f"  prepared 1024x1024 square from {w}x{h}")
PY

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon-source.png \
       --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon-source.png \
       --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
xattr -c Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns - now run ./build.sh install"
