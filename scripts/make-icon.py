#!/usr/bin/env python3
"""
Turn the NotchHub source artwork (solid-blue squircle with a notch cutout on a
white background) into a transparent, Apple-grid-padded 1024x1024 PNG that the
iconset builder consumes.

White (both the outer background and the notch cutout) becomes transparent; the
tile colour is normalised to its solid blue so edges stay clean with no halo.
"""
import sys
from PIL import Image

SRC = sys.argv[1]
OUT = sys.argv[2]

CANVAS = 1024           # final icon canvas
TILE_FRAC = 0.80        # squircle occupies ~80% of canvas (Apple macOS grid)

img = Image.open(SRC).convert("RGBA")
px = img.load()
w, h = img.size

# Sample the tile colour from the centre (solidly inside the squircle).
tile_rgb = img.getpixel((w // 2, h // 2))[:3]

# Build an alpha mask from the per-pixel min channel: white bg/notch -> high min
# (transparent), saturated blue tile -> low min (opaque). Linear feather between
# thresholds gives smooth anti-aliased edges with no white fringe.
LO, HI = 120, 235
out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
op = out.load()
for y in range(h):
    for x in range(w):
        r, g, b, _ = px[x, y]
        m = min(r, g, b)
        if m <= LO:
            a = 255
        elif m >= HI:
            a = 0
        else:
            a = int(round((HI - m) / (HI - LO) * 255))
        op[x, y] = (tile_rgb[0], tile_rgb[1], tile_rgb[2], a)

# Crop tight to the visible shape.
bbox = out.getbbox()
shape = out.crop(bbox)

# Scale the shape so its longest side fits the target tile fraction, then centre
# it on a transparent square canvas.
target = int(CANVAS * TILE_FRAC)
sw, sh = shape.size
scale = target / max(sw, sh)
shape = shape.resize((round(sw * scale), round(sh * scale)), Image.LANCZOS)

canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
ox = (CANVAS - shape.width) // 2
oy = (CANVAS - shape.height) // 2
canvas.alpha_composite(shape, (ox, oy))
canvas.save(OUT)
print(f"tile colour rgb={tile_rgb}  source={img.size}  shape={bbox}  -> {OUT}")
