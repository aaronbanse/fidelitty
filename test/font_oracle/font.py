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


def draw_box(pen, x0, y0, x1, y1):
    pen.moveTo((x0, y0))
    pen.lineTo((x0, y1))
    pen.lineTo((x1, y1))
    pen.lineTo((x1, y0))
    pen.closePath()


# TODO: implement replication padding
def render_glyph(pen, mask, cols, rows, replication_pad=False):
    """Draw a binary mask into a glyph.

    Args:
        pen: TTGlyphPen instance
        mask: flat list/array of cols*rows binary values (0 or 1),
              row-major order (top-left to bottom-right)
        cols: num columns in glyph mask
        rows: num rows in glyph mask
    """
    cell_w = ADVANCE / cols
    cell_h = (ASCENT + DESCENT) / rows

    for idx, value in enumerate(mask):
        if value == 0:
            continue
        col = idx % cols
        row = idx // cols
        x0 = col * cell_w
        y1 = ASCENT - row * cell_h
        y0 = ASCENT - (row + 1) * cell_h
        x1 = x0 + cell_w
        draw_box(pen, x0, y0, x1, y1)


def build_font(glyphs_data, output_path, cols, rows):
    """Build a TTF font from a list of quantized masks.

    Args:
        glyphs_data: list of flat arrays/lists, each with cols*rows values
        output_path: path to save the .ttf file
        cols: num columns per glyph mask
        rows: num rows per glyph mask
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
    fb.setupHorizontalHeader(ascent=ASCENT, descent=-DESCENT)
    fb.setupOS2(
        sTypoAscender=ASCENT,
        sTypoDescender=-DESCENT,
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
    fb.setupPost(keepGlyphNames=False)
    fb.save(output_path)
    print(f"Saved font with {n} glyphs ({cols}x{rows}) to {output_path}")

