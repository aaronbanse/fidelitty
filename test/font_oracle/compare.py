"""Build a test font with binary glyphs, then render them."""

import os
import subprocess

from PIL import Image, ImageDraw, ImageFont

from font import CODEPOINT_START_IDX, build_font

LEVELS = [0, 1]


def main():
    # One glyph per level: all cells set to that level
    glyphs = []
    for v in LEVELS:
        glyphs.append([v] * 16)
    build_font(glyphs, "test_values.ttf", cols=4, rows=4)

    # Render each glyph side by side at high res
    font_size = 512
    font = ImageFont.truetype("test_values.ttf", size=font_size)
    pad = 20
    cell_size = font_size + pad * 2
    label_h = 40
    img_w = cell_size * len(LEVELS)
    img_h = cell_size + label_h

    img = Image.new("L", (img_w, img_h), 255)
    d = ImageDraw.Draw(img)

    for i, v in enumerate(LEVELS):
        ch = chr(CODEPOINT_START_IDX + i)
        x = i * cell_size + pad
        d.text((x, pad), ch, fill=0, font=font)
        d.text((x + pad, cell_size), str(v), fill=0)

    out = "test_values.png"
    img.save(out)
    print(f"Saved {out}")
    try:
        subprocess.run(["sxiv", out])
    except FileNotFoundError:
        pass
    os.remove(out)
    os.remove("test_values.ttf")


if __name__ == "__main__":
    main()
