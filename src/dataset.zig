const config = @import("dataset_config");
const bitmask_set = @import("bitmask_set.zig");
const glyph = @import("glyph.zig");

pub const cell_w = config.cell_w;
pub const cell_h = config.cell_h;
pub const bitmasks = bitmask_set.generate(cell_w, cell_h);
pub const num_glyphs = bitmasks.len;

const UnicodeGlyphDataset = glyph.UnicodeGlyphDataset(
    cell_w,
    cell_h,
    &bitmasks,
    codepoint_start,
);
const instance: UnicodeGlyphDataset = .init();

pub const codepoints = instance.codepoints;
pub const masks = instance.masks;
pub const color_eqns = instance.color_eqns;

pub const GlyphMask = glyph.GlyphMask(cell_w, cell_h);
pub const ColorEqnCache = glyph.ColorEqnCache;

pub const notdef_glyph_id = 0;
pub const first_real_glyph_id = 1;
pub const codepoint_start = config.codepoint_start;
pub const codepoint_end = codepoint_start + num_glyphs - 1;
pub inline fn codepointForIndex(i: usize) u32 {
    return codepoint_start + first_real_glyph_id + i;
}
pub inline fn glyphIdForIndex(i: usize) u16 {
    return first_real_glyph_id + i;
}
