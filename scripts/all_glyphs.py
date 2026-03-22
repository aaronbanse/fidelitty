"""Generate a TTF containing all 2^16 binary 4x4 glyphs."""

import argparse

from font import build_font


def main():
    parser = argparse.ArgumentParser(description="Generate TTF with all binary 3x4 glyphs")
    parser.add_argument("--out", default="fidelitty.ttf", help="Output TTF path")
    args = parser.parse_args()

    cols, rows = 4, 4
    n_cells = cols * rows
    glyphs = []
    for i in range(1, 2 ** n_cells - 1):  # skip all-blank and all-filled to fit uint16 limit
        mask = [float((i >> bit) & 1) for bit in range(n_cells)]
        glyphs.append(mask)

    print(f"Generated {len(glyphs)} glyphs")
    build_font(glyphs, args.out, cols=cols, rows=rows)


if __name__ == "__main__":
    main()
