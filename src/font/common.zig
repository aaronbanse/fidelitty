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

        pub fn write(self: @This(), buf: []u8) void {
            @memcpy(buf[0..self.raw.len], &self.raw);
        }
    };
}

/// Builds a 16.16 fixed-point number: integer part in the high u16,
/// fractional part in the low u16. Used for sfnt version/revision fields.
pub fn fixed16_16(integer: u16, fraction: u16) u32 {
    return (@as(u32, integer) << 16) | fraction;
}
