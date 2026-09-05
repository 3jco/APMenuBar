#!/bin/bash
# Build Resources/AppIcon.icns.
#
#   ./make-icon.sh <source.png> [overrides-dir]
#
# <source.png>    artwork used for every size (ideally 1024x1024)
# [overrides-dir] optional folder of hand-authored PNGs; any square file whose
#                 pixel size matches an iconset slot replaces the scaled version.
#                 Hand-drawn 16 and 32 matter most: those are what the menu bar
#                 actually draws, and downscaled detail turns to mush there.
#
# Opaque backgrounds are flood-filled from the edges (the outline stops the fill,
# so enclosed pale areas survive) and non-square art is padded, never squashed.
set -euo pipefail
cd "$(dirname "$0")"
SRC="${1:?usage: ./make-icon.sh <source.png> [overrides-dir]}"
OVERRIDES="${2:-}"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

python3 - "$SRC" "$SET" "$OVERRIDES" <<'PY'
import os, re, sys
from collections import deque
from PIL import Image

src_path, iconset, overrides = sys.argv[1], sys.argv[2], sys.argv[3]

def strip_background(img, label):
    """Flood-fill the surround away if the corner is opaque."""
    w, h = img.size
    px = img.load()
    if px[0, 0][3] != 255:
        print(f"  {label}: already transparent")
        return img
    seed = px[0, 0][:3]
    TOL = 45
    near = lambda c: sum((a - b) ** 2 for a, b in zip(c[:3], seed)) <= TOL * TOL
    seen = [[False] * w for _ in range(h)]
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if near(px[x, y]): q.append((x, y)); seen[y][x] = True
    for y in range(h):
        for x in (0, w - 1):
            if near(px[x, y]) and not seen[y][x]: q.append((x, y)); seen[y][x] = True
    cleared = 0
    while q:
        x, y = q.popleft()
        r, g, b, _ = px[x, y]
        px[x, y] = (r, g, b, 0)
        cleared += 1
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and near(px[nx, ny]):
                seen[ny][nx] = True
                q.append((nx, ny))
    print(f"  {label}: cleared {100 * cleared / (w * h):.1f}%")
    return img

# --- base artwork -----------------------------------------------------------
img = strip_background(Image.open(src_path).convert("RGBA"), os.path.basename(src_path))
img = img.crop(img.getbbox())
side = int(max(img.size) * 1.10)                 # ~5% breathing room each side
canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2), img)
base = canvas.resize((1024, 1024), Image.LANCZOS)
base.save("Resources/AppIcon-source.png")

SLOTS = [("icon_16x16", 16), ("icon_16x16@2x", 32),
         ("icon_32x32", 32), ("icon_32x32@2x", 64),
         ("icon_128x128", 128), ("icon_128x128@2x", 256),
         ("icon_256x256", 256), ("icon_256x256@2x", 512),
         ("icon_512x512", 512), ("icon_512x512@2x", 1024)]

for name, size in SLOTS:
    base.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name + ".png"))

# --- hand-authored overrides ------------------------------------------------
if overrides and os.path.isdir(overrides):
    by_size = {}
    for entry in sorted(os.listdir(overrides)):
        path = os.path.join(overrides, entry)
        if not entry.lower().endswith(".png") or not os.path.isfile(path):
            continue
        if os.path.abspath(path) == os.path.abspath(src_path):
            continue                              # the source is not an override
        im = Image.open(path).convert("RGBA")
        if im.width > 64:
            # Large sizes must all come from one master, or the icon subtly
            # changes character between sizes. Hand-authoring pays off only at
            # the small end, where downscaling destroys detail.
            print(f"  skip {entry}: {im.width}px — large sizes come from the source")
            continue
        if im.width != im.height:
            print(f"  skip {entry}: not square ({im.width}x{im.height})")
            continue
        # Guard against mislabelled files: if the name states a size, it must
        # match the pixels. "Cat 32x32.png" that is really 16x16 gets skipped.
        stated = [int(n) for n in re.findall(r"\d+", entry)]
        if stated and im.width not in stated:
            print(f"  skip {entry}: named {stated} but is {im.width}x{im.width}")
            continue
        by_size.setdefault(im.width, (entry, im))

    for name, size in SLOTS:
        if size in by_size:
            entry, im = by_size[size]
            im = strip_background(im.copy(), entry)
            im.save(os.path.join(iconset, name + ".png"))
            print(f"  {name} ({size}px) <- {entry}")
PY

iconutil -c icns "$SET" -o Resources/AppIcon.icns
xattr -c Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns - now run ./build.sh install"
