"""Render a single glyph from a font file by codepoint."""

import argparse
import os
import subprocess

from PIL import Image, ImageDraw, ImageFont


def main():
    parser = argparse.ArgumentParser(description="Render a glyph by hex codepoint")
    parser.add_argument("font", help="Path to .ttf/.otf font file")
    parser.add_argument("codepoint", help="Hex codepoint (e.g. 41 for 'A')")
    parser.add_argument("--size", type=int, default=128, help="Image size in pixels")
    parser.add_argument("--out", type=str, default="glyph.png", help="Output image")
    args = parser.parse_args()

    ch = chr(int(args.codepoint, 16))
    font = ImageFont.truetype(args.font, size=int(args.size * 0.75))

    img = Image.new("L", (args.size, args.size), 255)
    d = ImageDraw.Draw(img)
    bbox = d.textbbox((0, 0), ch, font=font)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = (args.size - w) // 2 - bbox[0]
    y = (args.size - h) // 2 - bbox[1]
    d.text((x, y), ch, fill=0, font=font)

    img.save(args.out)
    subprocess.run(["sxiv", args.out])
    os.remove(args.out)


if __name__ == "__main__":
    main()
