//! Shared constants and low-level helpers for font generation.

const std = @import("std");
const config = @import("config");
const glyph = @import("../glyph.zig");
const bitmask_set = @import("../bitmask_set.zig");

pub const cell_w = config.cell_w;
pub const cell_h = config.cell_h;

pub const bitmasks = bitmask_set.generate(cell_w, cell_h);

/// Number of real glyphs (one per bitmask).
pub const num_glyphs = bitmasks.len;
/// Total glyphs written to the font: real glyphs plus the reserved `.notdef`
/// glyph at ID 0. OpenType mandates glyph ID 0 be `.notdef`; a cmap lookup
/// returning 0 means "no glyph", which renders as tofu — so real glyphs must
/// start at ID 1.
pub const total_glyphs = num_glyphs + 1;

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
