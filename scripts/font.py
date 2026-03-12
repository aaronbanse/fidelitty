import math

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

CODEPOINT_START_IDX = 0xF5000

UPM = 1000
ASCENT = 950
DESCENT = 250
# total height = 1200
LINE_GAP = 0
ADVANCE = 600

NAME_STRINGS = {
    "familyName": "Fidelitty Glyph Set",
    "styleName": "Regular",
    "psName": "Fidelitty-Glyph-Set",
    "fullName": "Fidelitty Glyph Set",
    "version": "Version 1.0",
}


def draw_line(pen, x0, y0, x1, y1, c):
    dx = x1 - x0
    dy = y1 - y0
    length = math.hypot(dx, dy)
    if length == 0:
        return
    nx = -dy / length * c / 2
    ny =  dx / length * c / 2
    pen.moveTo((x0 + nx, y0 + ny))
    pen.lineTo((x1 + nx, y1 + ny))
    pen.lineTo((x1 - nx, y1 - ny))
    pen.lineTo((x0 - nx, y0 - ny))
    pen.closePath()


def draw_box(pen, x0, y0, x1, y1):
    pen.moveTo((x0, y0))
    pen.lineTo((x0, y1))
    pen.lineTo((x1, y1))
    pen.lineTo((x1, y0))
    pen.closePath()


def render_glyph(pen, quantized_mask, cols=4, rows=4, n_low=3):
    """Draw a quantized mask into a glyph using diagonal lines.

    Args:
        pen: TTGlyphPen instance
        quantized_mask: flat list/array of cols*rows values in {0, 0.25, 0.5, 0.75, 1},
                        row-major order (top-left to bottom-right)
        cols: number of columns (patch width)
        rows: number of rows (patch height)
        n_low: number of diagonal lines for the lowest non-zero level (0.25)
    """
    cell_w = ADVANCE / cols
    cell_h = (ASCENT + DESCENT) / rows

    for idx, value in enumerate(quantized_mask):
        if value == 0:
            continue
        col = idx % cols
        row = idx // cols
        # Font coordinates: y=0 is baseline, y grows up.
        # Row 0 is top of glyph (highest y), row (rows-1) is bottom.
        x0 = col * cell_w
        y1 = ASCENT - row * cell_h        # top of cell
        y0 = ASCENT - (row + 1) * cell_h  # bottom of cell
        x1 = x0 + cell_w

        if value == 1:
            draw_box(pen, x0, y0, x1, y1)
        else:
            n_lines = round(value * 4 * n_low)
            line_thickness = cell_h / 20
            # Evenly spaced parallel diagonal lines sweeping across full cell
            for j in range(n_lines):
                # s sweeps from 0 to 2: 0..1 = bottom-left triangle, 1..2 = top-right triangle
                s = 2 * (j + 1) / (n_lines + 1)
                if s <= 1:
                    # Bottom edge to left edge
                    draw_line(pen, x0 + s * cell_w, y0, x0, y0 + s * cell_h, line_thickness)
                else:
                    # Right edge to top edge
                    u = s - 1
                    draw_line(pen, x1, y0 + u * cell_h, x0 + u * cell_w, y1, line_thickness)


def build_font(glyphs_data, output_path, cols=4, rows=4):
    """Build a TTF font from a list of quantized masks.

    Args:
        glyphs_data: list of flat arrays/lists, each with cols*rows values
        output_path: path to save the .ttf file
        cols: number of columns per glyph (patch width)
        rows: number of rows per glyph (patch height)
    """
    n = len(glyphs_data)
    names = [f'ftty_{i}' for i in range(n)]
    names.insert(0, '.notdef')
    metrics = {name: (ADVANCE, 0) for name in names}
    char_map = {CODEPOINT_START_IDX + i: names[i + 1] for i in range(n)}

    fb = FontBuilder(UPM)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap(char_map)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=ASCENT, descent=DESCENT)
    fb.setupOS2(
        sTypoAscender=ASCENT,
        sTypoDescender=DESCENT,
        sTypoLineGap=LINE_GAP,
        usWinAscent=ASCENT,
        usWinDescent=DESCENT,
    )
    fb.setupNameTable(NAME_STRINGS)

    glyphs = {}

    pen = TTGlyphPen(None)
    glyphs[".notdef"] = pen.glyph()

    for i, mask in enumerate(glyphs_data):
        pen = TTGlyphPen(None)
        render_glyph(pen, mask, cols=cols, rows=rows)
        glyphs[names[i + 1]] = pen.glyph()

    fb.setupGlyf(glyphs=glyphs)
    fb.setupPost()
    fb.save(output_path)
    print(f"Saved font with {n} glyphs ({cols}x{rows}) to {output_path}")


if __name__ == "__main__":
    # Test: build a font with a few example glyphs
    test_glyphs = [
        [1, 0, 0, 1,
         0, 0.5, 0.5, 0,
         0, 0.25, 0.75, 0,
         1, 0, 0, 1],
        [0.25, 0.5, 0.75, 1,
         0.25, 0.5, 0.75, 1,
         0.25, 0.5, 0.75, 1,
         0.25, 0.5, 0.75, 1],
    ]
    build_font(test_glyphs, "test.ttf", cols=4, rows=4)
