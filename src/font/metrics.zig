//! Reads vertical/horizontal metrics from the user's source font.

const std = @import("std");
const Io = std.Io;

const c = @import("font_c");

/// Metrics needed from the user font to properly size fidelitty font to fill each terminal cell.
/// The fidelitty font's metrics may differ.
pub const FontMetrics = struct {
    ascent: i16,
    descent: i16,
    line_gap: i16,
    advance_width: u16,
    units_per_em: u16,
};

/// OpenType constrains `unitsPerEm` to [16, 16384]. A value outside this range
/// means the font data was misparsed (e.g. garbage bytes from a bad mapping).
const min_units_per_em = 16;
const max_units_per_em = 16384;

pub fn getFontMetrics(io: Io, user_font_path: []const u8) !FontMetrics {
    // try absolute path and relative path
    const font_file: Io.File = blk: {
        if (Io.Dir.cwd().openFile(io, user_font_path, .{})) |file| {
            break :blk file;
        } else |_| {
            break :blk try Io.Dir.openFileAbsolute(io, user_font_path, .{});
        }
    };
    defer font_file.close(io);

    const font_stats = try font_file.stat(io);
    const font_size = font_stats.size;

    if (font_size == 0) return error.FontFileEmpty;

    const map = c.mmap(null, font_size, c.PROT_READ, c.MAP_PRIVATE, font_file.handle, 0);
    if (map == c.MAP_FAILED) return error.FontMmapFailed;
    defer _ = c.munmap(map, font_size);

    const font_data: [*]const u8 = @ptrCast(map);

    var font: c.stbtt_fontinfo = undefined;
    if (c.stbtt_InitFont(&font, font_data, 0) == 0) {
        return error.InitFontFailed;
    }

    var ascent: c_int = undefined;
    var descent: c_int = undefined;
    var line_gap: c_int = undefined;
    var advance_width: c_int = undefined;
    c.stbtt_GetFontVMetrics(&font, &ascent, &descent, &line_gap);
    c.stbtt_GetCodepointHMetrics(&font, 'W', &advance_width, null);

    // test widest vs thinnest character to ensure font is monospace
    var thin_codepoint_advance: c_int = undefined;
    c.stbtt_GetCodepointHMetrics(&font, 'i', &thin_codepoint_advance, null);
    if (thin_codepoint_advance != advance_width) return error.FontNotMonospace;
    // A zero advance passes the monospace check above (0 == 0) but is never
    // valid; catch it so misparsed fonts fail loudly instead of producing
    // zero-sized glyphs downstream.
    if (advance_width <= 0) return error.FontMissingAdvanceWidth;

    // stb_truetype has no direct unitsPerEm getter; invert the em->pixel
    // scale, which is defined as 1.0 / unitsPerEm.
    const em_scale = c.stbtt_ScaleForMappingEmToPixels(&font, 1.0);
    if (em_scale <= 0) return error.FontInvalidScale;
    const units_per_em = @round(1.0 / em_scale);
    if (units_per_em < min_units_per_em or units_per_em > max_units_per_em) {
        return error.FontInvalidUnitsPerEm;
    }

    return .{
        .ascent = std.math.cast(i16, ascent) orelse return error.FontMetricsOutOfRange,
        .descent = std.math.cast(i16, descent) orelse return error.FontMetricsOutOfRange,
        .line_gap = std.math.cast(i16, line_gap) orelse return error.FontMetricsOutOfRange,
        .advance_width = std.math.cast(u16, advance_width) orelse return error.FontMetricsOutOfRange,
        .units_per_em = @intFromFloat(units_per_em),
    };
}
