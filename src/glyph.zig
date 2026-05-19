const std = @import("std");
const math = std.math;
const debug = std.debug;
const Io = std.Io;

const codepoint_start = @import("config").codepoint_start;

/// Data structure storing a vector mask of vals in [0,1] of the positive and negative space of a glyph.
pub fn GlyphMask(comptime cell_w: u8, comptime cell_h: u8) type {
    const GPU_VEC4_ALIGN = 16;
    return extern struct {
        neg: [cell_w*cell_h]f32 align(GPU_VEC4_ALIGN),
        pos: [cell_w*cell_h]f32 align(GPU_VEC4_ALIGN),
    };
}

/// Stores glyph-dependent color solver params that can be computed at compile time
pub const ColorEqnCache = extern struct {
    BB: f32,  // B dot B
    FF: f32,  // F dot F
    BF: f32,  // B dot F
    det: f32, // FF*BB - BF*BF

    pub fn compute(comptime cell_w: u8, comptime cell_h: u8, mask: GlyphMask(cell_w, cell_h)) ColorEqnCache {
        const cell_size = cell_w * cell_h;
        return .{
            .BB = dot(cell_size, &mask.neg, &mask.neg),
            .FF = dot(cell_size, &mask.pos, &mask.pos),
            .BF = dot(cell_size, &mask.neg, &mask.pos),
            .det = dot(cell_size, &mask.neg, &mask.neg) * dot(cell_size, &mask.pos, &mask.pos)
                 - dot(cell_size, &mask.neg, &mask.pos) * dot(cell_size, &mask.neg, &mask.pos)
        };
    }
};

fn dot(dims: u8, a: []const f32, b: []const f32) f32 {
    debug.assert(@as(usize, dims) == a.len and a.len == b.len);
    var sum: f32 = 0;
    for (0..dims) |n| {
        sum += a[n] * b[n];
    }
    return sum;
}

pub fn UnicodeGlyphDataset(comptime cell_w: u8, comptime cell_h: u8) type {
    const MAX_GLYPHS = 65535; // limitation of opentype spec
    // Exclude the first and last bit patterns — the all-background and
    // all-foreground cells. Both are degenerate in the color solver and
    // would require special handling, and can be represented with any glyph
    // with fg and bg set the same color.

    // Dropping pattern 0 shifts the mapping to `entry i -> pattern i + 1`;
    // dropping the full pattern is the `- 2` in the count.
    const n: u32 = @min((1 << cell_w * cell_h) - 2, MAX_GLYPHS);
    return struct {
        codepoints: [n]u32,
        masks: [n]GlyphMask(cell_w, cell_h),
        color_eqns: [n]ColorEqnCache,

        pub fn init() @This() {
            var self: @This() = undefined;
            for (0..n) |i| {
                const pattern = i + 1; // entry i maps to pattern i+1 (pattern 0 is excluded)
                self.codepoints[i] = @as(u32, @intCast(i)) + codepoint_start;
                for (0..(cell_w * cell_h)) |bit| {
                    const bit_on: bool = ((pattern >> @intCast(bit)) & 1 == 1);
                    self.masks[i].pos[bit] = if (bit_on) 1 else 0;
                    self.masks[i].neg[bit] = if (bit_on) 0 else 1;
                }
                self.color_eqns[i] = ColorEqnCache.compute(cell_w, cell_h, self.masks[i]);
            }
            return self;
        }

        pub fn numCodepoints() u32 {
            return n;
        }
    };
}
