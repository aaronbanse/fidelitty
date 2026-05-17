//! Shared constants and low-level helpers for font generation.

const std = @import("std");
const config = @import("config");
const glyph = @import("../glyph.zig");

pub const cell_w = config.cell_w;
pub const cell_h = config.cell_h;
pub const num_glyphs = glyph.UnicodeGlyphDataset(cell_w, cell_h).numCodepoints();

// TODO: figure out more informed values for these, and where they should live.
pub const MAX_CONTOURS = 36;
pub const MAX_GLYPH_SIZE = 1024;

pub fn Big(comptime T: type) type {
    return extern struct {
        raw: [@sizeOf(T)]u8,

        pub fn from(val: T) @This() {
            return .{ .raw = @bitCast(std.mem.nativeToBig(T, val)) };
        }
    };
}

pub fn writeBytes(buf: []u8, v: anytype) void {
    const bytes = std.mem.asBytes(&v);
    @memcpy(buf[0..bytes.len], bytes);
}
