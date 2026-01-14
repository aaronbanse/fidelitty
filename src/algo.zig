const std = @import("std");
const math = std.math;

const patch = @import("image_patch.zig");
const glyph = @import("glyph.zig");
const uni_im = @import("unicode_image.zig");

// Data structure for storing precomputed values for finding the optimal colors for the glyph to represent a given patch
pub fn glyphColorSolver(
    comptime w: u8,
    comptime h: u8,
    g: glyph.GlyphMask(w,h),
) GlyphColorSolver(w, h) {
    const B = @as(@Vector(w*h, f32), g.neg);
    const F = @as(@Vector(w*h, f32), g.pos);
    return GlyphColorSolver(w, h) {
        .B = B,
        .F = F,
        .BB = @reduce(.Add, B * B),
        .FF = @reduce(.Add, F * F),
        .BF = @reduce(.Add, B * F),
        .det = @reduce(.Add, B * B) * @reduce(.Add, F * F) - @reduce(.Add, B * F) * @reduce(.Add, B * F)
    };
}

pub fn computePixel(
    comptime w: u8,
    comptime h: u8,
    im_patch: patch.ImagePatch(w, h),
    codepoints: []u32,
    glyphs: []glyph.GlyphMask(w, h),
    glyph_color_solvers: []GlyphColorSolver(w, h)
) uni_im.UnicodePixelData {
    var best_diff: u16 = math.maxInt(u16);
    var best_n: usize = 0;
    for (0..glyphs.len) |n| {
        const rec_colors = glyph_color_solvers[n].solve(im_patch);
        const rec = glyphPatchReconstruction(w, h, rec_colors, glyphs[n]);
        const rec_diff = patchDiff(w, h, rec, im_patch);
        best_n = if (rec_diff < best_diff) n else best_n;
        best_diff = @min(rec_diff, best_diff);
    }

    // faster to recompute once than call N conditional moves
    var pixel = glyph_color_solvers[best_n].solve(im_patch);
    pixel.codepoint = codepoints[best_n];
    return pixel;
}

// Outside debuggin, do not need to use functions below. ----------------

pub fn GlyphColorSolver(comptime w: u8, comptime h: u8) type {
    return struct {
        B: @Vector(w*h, f32), // glyph background mask
        F: @Vector(w*h, f32), // glyph foreground mask
        BB: f32, // B dot B
        FF: f32, // F dot F
        BF: f32, // B dot F  /  F dot B
        det: f32, // FF*BB - BF*BF

        pub fn solve(self: GlyphColorSolver(w, h), im_patch: patch.ImagePatch(w, h)) uni_im.UnicodePixelData {
            const r = self.solveChannel(im_patch.r);
            const g = self.solveChannel(im_patch.g);
            const b = self.solveChannel(im_patch.b);
            return .{ .br = r.C_b, .bg = g.C_b, .bb = b.C_b, .fr = r.C_f, .fg = g.C_f, .fb = b.C_f, .codepoint = undefined};
        }

        fn solveChannel(self: GlyphColorSolver(w, h), im_patch: @Vector(w*h, u8)) struct { C_b: u8, C_f: u8 } {
            const P: @Vector(w*h, f32) = @floatFromInt(im_patch);
            const C_b_num = @reduce(.Add, P * self.B) * self.FF - @reduce(.Add, P * self.F) * self.BF;
            const C_f_num = @reduce(.Add, P * self.F) * self.BB - @reduce(.Add, P * self.B) * self.BF;
            const C_b = math.clamp(C_b_num / self.det, 0, 255);
            const C_f = math.clamp(C_f_num / self.det, 0, 255);
            return .{ .C_b = @intFromFloat(C_b), .C_f = @intFromFloat(C_f) };
        }
    };
}

pub fn glyphPatchReconstruction(
    comptime w: u8,
    comptime h: u8,
    colors: uni_im.UnicodePixelData,
    g: glyph.GlyphMask(w, h)
) patch.ImagePatch(w, h) {
    const r_rec = @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.br))) * g.neg
                + @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.fr))) * g.pos;
    const g_rec = @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.bg))) * g.neg
                + @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.fg))) * g.pos;
    const b_rec = @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.bg))) * g.neg
                + @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.fg))) * g.pos;
    return .{ .r = @intFromFloat(r_rec), .g = @intFromFloat(g_rec), .b = @intFromFloat(b_rec) };
}

pub fn patchDiff(comptime w: u8, comptime h: u8, a: patch.ImagePatch(w, h), b: patch.ImagePatch(w, h)) u16 {
    // abs difference via saturation subtraction, and promote to u16 for future reduce operation
    const r_diff: @Vector(w*h, u16) = (a.r -| b.r) | (b.r -| a.r);
    const g_diff: @Vector(w*h, u16) = (a.g -| b.g) | (b.g -| a.g);
    const b_diff: @Vector(w*h, u16) = (a.b -| b.b) | (b.b -| a.b);
    return @reduce(.Add, r_diff + g_diff + b_diff);
}

