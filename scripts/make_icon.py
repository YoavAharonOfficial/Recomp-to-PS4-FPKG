#!/usr/bin/env python3
"""make_icon.py OUT.png "LINE1" "LINE2" [#accent]

Generic 512x512 PS4 icon0.png for a snesrecomp-ps4 title: an original
abstract design (no game artwork or logos) with two lines of text."""
import sys
from PIL import Image, ImageDraw, ImageFont

BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
REG = "/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed.ttf"


def main(out, line1, line2, accent="#3aa0ff"):
    size = 512
    img = Image.new("RGB", (size, size), "#0d1424")
    d = ImageDraw.Draw(img)
    # Diagonal light bands.
    for i, alpha in enumerate((40, 26, 16)):
        off = 140 + i * 70
        band = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        bd = ImageDraw.Draw(band)
        bd.polygon([(off, 0), (off + 46, 0), (off - 210, size), (off - 256, size)],
                   fill=(58, 160, 255, alpha))
        img.paste(band, (0, 0), band)
    # Pixel grid motif (a nod to 16-bit, nothing more).
    for y in range(36, 156, 24):
        for x in range(36, 156, 24):
            if (x + y) // 24 % 3:
                d.rectangle([x, y, x + 16, y + 16], fill=accent)
    d.rectangle([0, size - 150, size, size], fill="#111b30")
    d.rectangle([0, size - 154, size, size - 150], fill=accent)

    def fit(text, font_path, max_w, start):
        s = start
        while s > 10:
            f = ImageFont.truetype(font_path, s)
            if d.textlength(text, font=f) <= max_w:
                return f
            s -= 2
        return ImageFont.truetype(font_path, 10)

    f1 = fit(line1, BOLD, size - 60, 84)
    f2 = fit(line2, REG, size - 60, 40)
    d.text((30, size - 140), line1, font=f1, fill="#ffffff")
    d.text((32, size - 58), line2, font=f2, fill="#9fb4d8")
    img.save(out, "PNG")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
