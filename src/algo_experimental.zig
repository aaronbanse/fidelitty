const std = @import("std");
const image_patch = @import("image_patch.zig");
const glyph = @import("glyph.zig");
const debug = @import("debug.zig");
const unicode_image = @import("unicode_image.zig");

pub fn patchGlyphRepresentation(
    comptime w: u8,
    comptime h: u8,
    patch: image_patch.ImagePatch(w, h),
    codepoints: []u16, 
    glyphs: []glyph.GlyphPixmap(w, h),
    sums: []struct { neg: FixedPointDivisor, pos: FixedPointDivisor }
) struct { // return type
    pix: unicode_image.UnicodePixelData,
    reconstruction: struct { r: @Vector(w*h, u8), g: @Vector(w*h, u8), b: @Vector(w*h, u8) }
} {
    var best_pix: unicode_image.UnicodePixelData = undefined;
    var best_reconstruction: struct { r: @Vector(w*h, u8), g: @Vector(w*h, u8), b: @Vector(w*h, u8) } = undefined;
    var best_diff: u16 = std.math.maxInt(u16);

    var cur_pix: unicode_image.UnicodePixelData = undefined;
    for (0..codepoints.len) |n| {
        glyphMaskedColorAvg(w, h, patch, glyphs[n], &cur_pix, sums[n]);
        const rec = patchReconstruction(w, h, cur_pix, glyphs[n]);
        const diff = patchSAD(w, h, rec.r, patch.r) + patchSAD(w, h, rec.g, patch.g) + patchSAD(w, h, rec.b, patch.b);

        best_pix = if (diff < best_diff) cur_pix else best_pix;
        best_reconstruction = if (diff < best_diff) .{ .r = rec.r, .g = rec.g, .b = rec.b } else best_reconstruction;
        best_diff = @min(best_diff, diff);
    }

    return .{ .pix = best_pix, .reconstruction = best_reconstruction };
}

// pub fn bestGlyph(comptime w: u8, comptime h: u8, patch: image_patch.ImagePatch(w, h), codepoints: []u16, glyphs: []glyph.GlyphPixmap(w, h)) u16 {
//     std.debug.assert(codepoints.len == glyphs.len);
//     const size = w*h;
//
//     const patch_lum: @Vector(size, u8) = patchLuminosity(w, h, linRGB(w,h,patch.r), linRGB(w,h,patch.g), linRGB(w,h,patch.b));
//
//     // find glyph that best divides patch luminosity
//     var best_n: u16 = 0;
//     var smallest_diff: u32 = std.math.maxInt(u32);
//     for (0..codepoints.len) |n| {
//         const diff = scoreGlyphRawDiff(w, h, patch_lum, glyphs[n]);
//         best_n = if (diff < smallest_diff) @intCast(n) else best_n;
//         smallest_diff = @min(diff, smallest_diff);
//     }
//
//     return best_n;
// }

// HELPERS, ALGO COMPONENTS
// ------------------------------------------

fn scoreGlyphRawDiff(comptime w: u8, comptime h: u8, patch_lum: @Vector(w * h, u8), g: glyph.GlyphPixmap(w, h)) u32 {
    return @min(patchSAD(w, h, patch_lum, g.pixmap_pos), patchSAD(w, h, patch_lum, g.pixmap_neg));
}

// // convenience helper for debuggin, inefficient
// fn scoreGlyphDebug(comptime w: u8, comptime h: u8, patch: image_patch.ImagePatch(w, h), g: glyph.GlyphPixmap(w,h)) u32 {
//     const patch_lum: @Vector(w*h, u8) = patchLuminosity(w, h, linRGB(w,h,patch.r), linRGB(w,h,patch.g), linRGB(w,h,patch.b));
//     return scoreGlyphRawDiff(w, h, patch_lum, g);
// }

// bit shifts u16 vector by 8 and demotes to u8, effectively lowering "resolution" from u16 to u8
fn vecU16ToU8(comptime w: u8, comptime h: u8, v: @Vector(w*h, u16)) @Vector(w*h, u8) {
    return @truncate(v >> @splat(@as(u5, 8)));
}

// approximate sRGB to linearized RGB efficiently
fn linRGB(comptime w: u8, comptime h: u8, c: @Vector(w*h, u8)) @Vector(w*h, u8) {
    return vecU16ToU8(w, h, @as(@Vector(w*h, u16), c) * @as(@Vector(w*h, u16), c));
}

// pub fn norm(comptime w: u8, comptime h: u8, v: @Vector(w*h, u8)) @Vector(w*h, u8) {
//     // shift right to divide to compute avg - only works if w*h is power of 2
//     const R_SHIFT = comptime blk: {
//         std.debug.assert(@popCount(w*h) == 1);
//         break :blk @ctz(w*h);
//     };
//
//     const avg: u8 = @intCast(@reduce(.Add, @as(@Vector(w*h, u16), v)) >> @splat(@as(u5, R_SHIFT)));
//     return 
// }

// returns a LUT to convert sRGB to linearized RGB.
fn linRGBLookupTable(lut: []u8) void {
    const u8_vals: u16 = std.math.maxInt(u8) + 1;
    std.debug.assert(lut.len == u8_vals);

    for (0..u8_vals) |n| {
        const c: f32 = @as(f32, @floatFromInt(n)) / 255.0;
        const c_lin: f32 = if (c <= 0.04045) {
            c / 12.92;
        } else {
            std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
        };
        lut[n] = @intFromFloat(c_lin * 255.0);
    }
}

// Given a set of background / foreground colors and a glyph, returns the resulting image patch if you were to color the glyph's
// positive and negative space with their respective masked average over the original image patch.
pub fn patchReconstruction(comptime w: u8, comptime h: u8, colors: unicode_image.UnicodePixelData, g: glyph.GlyphPixmap(w, h))
struct { r: @Vector(w*h, u8), g: @Vector(w*h, u8), b: @Vector(w*h, u8) } {
    const rec_br = maskedSplat(w, h, colors.br, g.pixmap_neg);
    const rec_bg = maskedSplat(w, h, colors.bg, g.pixmap_neg);
    const rec_bb = maskedSplat(w, h, colors.bb, g.pixmap_neg);
    const rec_fr = maskedSplat(w, h, colors.fr, g.pixmap_pos);
    const rec_fg = maskedSplat(w, h, colors.fg, g.pixmap_pos);
    const rec_fb = maskedSplat(w, h, colors.fb, g.pixmap_pos);
    const rec_r = rec_br + rec_fr;
    const rec_g = rec_bg + rec_fg;
    const rec_b = rec_bb + rec_fb;

    return .{ .r = rec_r, .g = rec_g, .b = rec_b };
}

fn maskedSplat(comptime w: u8, comptime h: u8, val: u8, mask: @Vector(w*h, u8)) @Vector(w*h, u8) {
    return vecU16ToU8(w, h, @as(@Vector(w*h, u16), @splat(val)) * @as(@Vector(w*h, u16), mask));
}

// Converts a patch of rgb values to a patch of luminosity values,
// using the formula l = 0.2126*r + 0.7152*g + 0.0722*b
// fn patchLuminosity(comptime w: u8, comptime h: u8, r: @Vector(w*h, u8), g: @Vector(w*h, u8), b: @Vector(w*h, u8)) @Vector(w*h, u8) {
//     // constants for magic number division
//     const R_SHIFT: u5 = 24;
//     const MR: u32 = 13933; // 13933 / 2^16 ~= 0.2126
//     const MG: u32 = 46871; // 46871 / 2^16 ~= 0.7152
//     const MB: u32 = 4732; //   4732 / 2^16 ~= 0.0722
//
//     // promote to u32 to prevent overflow
//     const sum = @as(@Vector(w*h, u32), r) * @as(@Vector(w*h, u32), @splat(MR)) +
//                 @as(@Vector(w*h, u32), g) * @as(@Vector(w*h, u32), @splat(MG)) +
//                 @as(@Vector(w*h, u32), b) * @as(@Vector(w*h, u32), @splat(MB));
//     // our math ensures this is lossless, but avoid runtime check for performance
//     return @truncate(sum >> @as(@Vector(w*h, u5), @splat(R_SHIFT)));
// }

// abs value difference between two patches
fn patchSAD(comptime w: u8, comptime h: u8, a: @Vector(w*h, u8), b: @Vector(w*h, u8)) u16 {
    return @reduce(.Add, @as(@Vector(w*h, u16), (a -| b) | (b -| a)));
}

// Takes the dot product of two patches. Promotes to u32 to avoid overflow.
fn patchDotProduct(comptime w: u8, comptime h: u8, a: @Vector(w * h, u8), b: @Vector(w * h, u8)) u16 {
    const size = w * h;
    return @reduce(.Add, (@as(@Vector(size, u16), a) * @as(@Vector(size, u16), b) >> @splat(@as(u5, 8))));
}

// Takes the average value of c, pointwise-weighted by weights
fn weightedColorAvg(comptime w: u8, comptime h: u8, c: @Vector(w*h, u8), weights: @Vector(w*h, u8), weights_sum: FixedPointDivisor) u8 {
    // pointwise multiplication and normalization back to u8 range, then avg
    const c_weighted = @as(@Vector(w*h, u16), c) * @as(@Vector(w*h, u16), weights);
    const sum: u32 = @reduce(.Add, @as(@Vector(w*h, u32), c_weighted));
    return @intCast(weights_sum.apply(sum));
}

pub fn glyphMaskedColorAvg(
    comptime w: u8,
    comptime h: u8,
    patch: image_patch.ImagePatch(w,h),
    g: glyph.GlyphPixmap(w, h),
    pix: *unicode_image.UnicodePixelData, // write colors to this pixel data
    sum: GlyphMaskSumFixedPoints
) void {
    pix.br = weightedColorAvg(w, h, patch.r, g.pixmap_neg, sum.neg);
    pix.bg = weightedColorAvg(w, h, patch.g, g.pixmap_neg, sum.neg);
    pix.bb = weightedColorAvg(w, h, patch.b, g.pixmap_neg, sum.neg);
    pix.fr = weightedColorAvg(w, h, patch.r, g.pixmap_pos, sum.pos);
    pix.fg = weightedColorAvg(w, h, patch.g, g.pixmap_pos, sum.pos);
    pix.fb = weightedColorAvg(w, h, patch.b, g.pixmap_pos, sum.pos);
    // don't know the unicode for this glyph, just it's pixmap
}

pub const FixedPointDivisor = struct {
    m: u32,
    shift: u6,

    fn apply(self: FixedPointDivisor, n: u32) u32 {
        return @intCast((@as(u64, self.m) * @as(u64, n)) >> self.shift);
    }
};

pub fn computeFixedPoint(max_numerator: u32, d: u32) FixedPointDivisor {
    if (d == 0) return .{ .m = 0, .shift = 0 };
    const shift: u6 = 32 - @clz(max_numerator) + 1;
    return .{
        .m = @intCast(((@as(u64, 1) << shift) + d - 1) / d),
        .shift = shift,
    };
}

pub const GlyphMaskSumFixedPoints = struct { neg: FixedPointDivisor, pos: FixedPointDivisor };
