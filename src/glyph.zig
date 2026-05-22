//! Types passed to gpu for computing optimal glyph to represent a patch

const std = @import("std");
const math = std.math;
const debug = std.debug;
const Io = std.Io;

/// Stores a vector mask of vals in [0,1] of the positive and negative space of a glyph.
pub fn GlyphMask(comptime cell_w: u8, comptime cell_h: u8) type {
    const GPU_VEC4_ALIGN = 4 * @sizeOf(f32);
    return extern struct {
        neg: [cell_w * cell_h]f32 align(GPU_VEC4_ALIGN),
        pos: [cell_w * cell_h]f32 align(GPU_VEC4_ALIGN),
    };
}

/// Stores glyph-dependent color solver params that can be computed at compile time
pub const ColorEqnCache = extern struct {
    BB: f32, // B dot B
    FF: f32, // F dot F
    BF: f32, // B dot F
    det: f32, // FF*BB - BF*BF

    pub fn compute(
        comptime cell_w: u8,
        comptime cell_h: u8,
        mask: GlyphMask(cell_w, cell_h),
    ) ColorEqnCache {
        const cell_size = cell_w * cell_h;
        return .{
            .BB = dot(cell_size, &mask.neg, &mask.neg),
            .FF = dot(cell_size, &mask.pos, &mask.pos),
            .BF = dot(cell_size, &mask.neg, &mask.pos),
            // zig fmt: off
            .det = dot(cell_size, &mask.neg, &mask.neg)
                 * dot(cell_size, &mask.pos, &mask.pos)
                 - dot(cell_size, &mask.neg, &mask.pos)
                 * dot(cell_size, &mask.neg, &mask.pos),
            // zig fmt: on
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

/// Unified storage and validation for pre-computed glyph dataset values.
/// Parametrized on a set of bitmasks, and meant to be passed to the gpu.
pub fn UnicodeGlyphDataset(
    comptime cell_w: u8,
    comptime cell_h: u8,
    comptime bitmasks: []const u32,
    comptime codepoint_start: u32,
) type {
    const type_name = "UnicodeGlyphDataset";
    const MAX_GLYPHS = 65535;
    const n_glyphs = bitmasks.len;
    if (n_glyphs > MAX_GLYPHS) @compileError(std.fmt.comptimePrint(
        type_name ++ ": {d} bitmasks exceeds the OpenType spec limit ({d})",
        .{ n_glyphs, MAX_GLYPHS },
    ));

    @setEvalBranchQuota(n_glyphs + 1000);

    const bits = cell_w * cell_h;
    const bitmask_full: u32 = (1 << bits) - 1;
    for (0..n_glyphs) |i| {
        const bitmask = bitmasks[i];
        if (bitmask == 0 or bitmask == bitmask_full)
            @compileError(type_name ++ ": degenerate pattern (empty or full) not allowed");
        if (bitmask > bitmask_full) @compileError(std.fmt.comptimePrint(
            type_name ++ ": bitmask {d} too large for a cell of size {d}x{d}.",
            .{ bitmask, cell_w, cell_h },
        ));
    }

    return struct {
        codepoints: [n_glyphs]u32,
        masks: [n_glyphs]GlyphMask(cell_w, cell_h),
        color_eqns: [n_glyphs]ColorEqnCache,

        pub fn init() @This() {
            @setEvalBranchQuota(n_glyphs * 1000);
            var self: @This() = undefined;
            for (0..n_glyphs) |i| {
                const bitmask = bitmasks[i];
                self.codepoints[i] = @as(u32, @intCast(i)) + codepoint_start;
                for (0..(cell_w * cell_h)) |bit| {
                    const bit_on: bool = ((bitmask >> @intCast(bit)) & 1 == 1);
                    self.masks[i].pos[bit] = if (bit_on) 1 else 0;
                    self.masks[i].neg[bit] = if (bit_on) 0 else 1;
                }
                self.color_eqns[i] = ColorEqnCache.compute(cell_w, cell_h, self.masks[i]);
            }
            return self;
        }
    };
}
