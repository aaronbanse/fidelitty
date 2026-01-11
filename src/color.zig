const std = @import("std");

// comptime function to bake a LUT to convert sRGB to linearized RGB.
pub fn linRGBLookupTable(lut: []u8) void {
    const u8_vals: u16 = @as(comptime_int, 1) << @typeInfo(u8).int.bits;
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

// Converts a patch of rgb values to a patch of luminosity values,
// using the formula l = 0.2126*r + 0.7152*g + 0.0722*b
pub fn patchLuminosity(comptime w: u8, comptime h: u8, r: @Vector(w*h, u8), g: @Vector(w*h, u8), b: @Vector(w*h, u8)) @Vector(w*h, u8) {
    // constants for magic number division
    const R_SHIFT: u5 = 16;
    const MR: u32 = 13933; // 13933 / 2^16 ~= 0.2126
    const MG: u32 = 46871; // 46871 / 2^16 ~= 0.7152
    const MB: u32 = 4732; //   4732 / 2^16 ~= 0.0722

    // promote to u32 to prevent overflow
    const sum = r * @as(@Vector(w*h, u32), @splat(MR)) +
                g * @as(@Vector(w*h, u32), @splat(MG)) +
                b * @as(@Vector(w*h, u32), @splat(MB));

    // our math ensures this is lossless, but avoid runtime check for performance
    return @truncate(sum >> @as(@Vector(w*h, u5), @splat(R_SHIFT)));
}

// Takes the dot product of two patches. Promotes to u16 to avoid overflow.
pub fn patchDotProduct(comptime w: u8, comptime h: u8, u: @Vector(w*h, u8), v: @Vector(w*h, u8)) u16 {
    return @reduce(.Add, @as(@Vector(w*h, u16), u) * @as(@Vector(w*h, u16), v)); 
}

// Takes the average value of c, pointwise-weighted by weights
pub fn weightedColorAvg(comptime w: u8, comptime h: u8, c: @Vector(w*h, u8), weights: @Vector(w*h, u8)) u8 {
    // shift right to divide to compute avg - only works if w*h is power of 2
    const R_SHIFT = comptime blk: {
        std.debug.assert(@popCount(w*h) == 1);
        break :blk @ctz(w*h);
    };

    // pointwise multiplication and normalization back to u8 range, then avg
    const c_weighted = @as(@Vector(w*h, u16), c) * @as(@Vector(w*h, u16), weights);
    const c_weighted_small: @Vector(w*h, u8) = @truncate(c_weighted >> @splat(8));
    const sum: u16 = @reduce(.Add, c_weighted_small);
    return sum >> R_SHIFT;
}

