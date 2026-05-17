//! Reads vertical/horizontal metrics from the user's source font.

const std = @import("std");
const Io = std.Io;

const c = @import("c");

/// Metrics needed from the user font to properly size fidelitty font to fill each terminal cell.
/// The fidelitty font's metrics may differ.
pub const UserFontMetrics = struct {
    ascent: i16,
    descent: i16,
    line_gap: i16,
    advance_width: u16,
};

pub fn getFontMetrics(io: Io, user_font_path: []const u8) !UserFontMetrics {
    // try absolute path and relative path
    const font_file: Io.File = blk: {
        if (Io.Dir.cwd().openFile(io, user_font_path, .{})) |file| {
            break :blk file;
        } else |_| {
            break :blk try Io.Dir.openFileAbsolute(io, user_font_path, .{});
        }
    };
    const font_stats = try font_file.stat(io);
    const font_size = font_stats.size;
    // TODO: handle errors
    // TODO: unmap and close file
    const font_data: [*]const u8 = @ptrCast(c.mmap(
        null,
        font_size,
        c.PROT_READ,
        c.MAP_PRIVATE,
        font_file.handle,
        0,
    ));

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

    const metrics: UserFontMetrics = .{
        .ascent = @intCast(ascent),
        .descent = @intCast(descent),
        .line_gap = @intCast(line_gap),
        .advance_width = @intCast(advance_width),
    };

    return metrics;
}
