#!/usr/bin/env python3
"""Prepare the NotchHub artwork for the macOS icon grid.

The source is an RGBA brand master. Its real transparency and full colour are
preserved, the visible artwork is trimmed, and the result is centred on a
transparent 1024px canvas with Apple-style padding.
"""

import sys

from PIL import Image


CANVAS = 1024
TILE_FRAC = 0.80


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} SOURCE.png OUTPUT.png")

    source_path, output_path = sys.argv[1:]
    source = Image.open(source_path).convert("RGBA")
    visible_bounds = source.getchannel("A").getbbox()
    if visible_bounds is None:
        raise SystemExit("error: source artwork is fully transparent")

    artwork = source.crop(visible_bounds)
    target = round(CANVAS * TILE_FRAC)
    scale = min(target / artwork.width, target / artwork.height)
    output_size = (
        max(1, round(artwork.width * scale)),
        max(1, round(artwork.height * scale)),
    )
    artwork = artwork.resize(output_size, Image.Resampling.LANCZOS)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    origin = (
        (CANVAS - artwork.width) // 2,
        (CANVAS - artwork.height) // 2,
    )
    canvas.alpha_composite(artwork, origin)
    canvas.save(output_path, optimize=True)

    print(
        f"source={source.size} visible={visible_bounds} "
        f"artwork={artwork.size} origin={origin} -> {output_path}"
    )


if __name__ == "__main__":
    main()
