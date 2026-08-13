#!/usr/bin/env python3
"""Create a transparent 1024px macOS icon master from generated artwork."""

from pathlib import Path
import sys

from PIL import Image, ImageDraw


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "Usage: python3 Tools/make_app_icon.py <input.png> <output.png> <output.icns>",
            file=sys.stderr,
        )
        return 2

    source_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    icns_path = Path(sys.argv[3])

    with Image.open(source_path) as source:
        artwork = source.convert("RGBA").resize((1024, 1024), Image.Resampling.LANCZOS)

    # The generated artwork includes a dark outer canvas. Clip it to the visible
    # macOS icon silhouette so Finder and Launchpad receive transparent corners.
    mask = Image.new("L", (1024, 1024), 0)
    ImageDraw.Draw(mask).rounded_rectangle((60, 60, 964, 964), radius=190, fill=255)
    artwork.putalpha(mask)
    artwork.save(output_path, format="PNG", optimize=True)
    artwork.save(icns_path, format="ICNS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
