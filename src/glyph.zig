const std = @import("std");
const math = std.math;
const debug = std.debug;
const Io = std.Io;

const dataset_config = @import("dataset_config");

const term = @import("terminal_util.zig");

const c = @cImport({
    @cInclude("stb_truetype.h");
});

/// Data structure storing a vector mask of vals in [0,1] of the positive and negative space of a glyph.
pub fn GlyphMask(comptime w: u8, comptime h: u8) type {
    const GPU_VEC4_ALIGN = 16;
    return extern struct {
        neg: [w*h]f32 align(GPU_VEC4_ALIGN),
        pos: [w*h]f32 align(GPU_VEC4_ALIGN),
    };
}

pub fn UnicodeGlyphDataset(comptime w: u8, comptime h: u8) type {
    // Skip all-blank (0) and all-filled (2^n-1) patterns to match the font generator (all_glyphs.py)
    const total = std.math.pow(u32, @as(u32, 2), @as(u32, w) * @as(u32, h));
    const n: u32 = total - 2;
    return struct {
        codepoints: [n]u32,
        masks: [n]GlyphMask(w, h),
        color_eqns: [n]ColorEqnCache,

        pub fn init() @This() {
            var self: @This() = undefined;
            for (0..n) |i| {
                const pattern = i + 1; // patterns 1..total-2, skipping 0 and total-1
                self.codepoints[i] = @as(u32, @intCast(i)) + dataset_config.charset_start;
                for (0..(w * h)) |bit| {
                    const bit_on: bool = ((pattern >> @intCast(bit)) & 1 == 1);
                    self.masks[i].pos[bit] = if (bit_on) 1 else 0;
                    self.masks[i].neg[bit] = if (bit_on) 0 else 1;
                }
                self.color_eqns[i] = ColorEqnCache.compute(w, h, self.masks[i]);
            }
            return self;
        }

        pub fn numCodepoints() u32 {
            return n;
        }
    };
}

fn dot(dims: u8, a: []const f32, b: []const f32) f32 {
    debug.assert(@as(usize, dims) == a.len and a.len == b.len);
    var sum: f32 = 0;
    for (0..dims) |n| {
        sum += a[n] * b[n];
    }
    return sum;
}

/// Stores glyph-dependent color solver params that can be computed at compile time
pub const ColorEqnCache = extern struct {
    BB: f32,  // B dot B
    FF: f32,  // F dot F
    BF: f32,  // B dot F
    det: f32, // FF*BB - BF*BF

    pub fn compute(comptime w: u8, comptime h: u8, mask: GlyphMask(w,h)) ColorEqnCache {
        const dims = w * h;
        return .{
            .BB = dot(dims, &mask.neg, &mask.neg),
            .FF = dot(dims, &mask.pos, &mask.pos),
            .BF = dot(dims, &mask.neg, &mask.pos),
            .det = dot(dims, &mask.neg, &mask.neg) * dot(dims, &mask.pos, &mask.pos)
                 - dot(dims, &mask.neg, &mask.pos) * dot(dims, &mask.neg, &mask.pos)
        };
    }
};
