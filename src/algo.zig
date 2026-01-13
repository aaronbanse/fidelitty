const std = @import("std");
const image_patch = @import("image_patch.zig");
const glyph = @import("glyph.zig");
const unicode_image = @import("unicode_image.zig");

pub fn glyphColorSolver(
    comptime w: u8,
    comptime h: u8,
    g: glyph.GlyphPixmap(w,h),
) GlyphColorSolver(w, h) {
    const B = @as(@Vector(w*h, f32), g.pixmap_neg);
    const F = @as(@Vector(w*h, f32), g.pixmap_pos);
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
    patch: image_patch.ImagePatch(w, h),
    codepoints: []u32,
    glyphs: []glyph.GlyphPixmap(w, h),
    glyph_color_solvers: []GlyphColorSolver(w, h)
) unicode_image.UnicodePixelData {
    var best_diff: u16 = std.math.maxInt(u16);
    var best_n: usize = 0;
    for (0..glyphs.len) |n| {
        const rec_colors = glyph_color_solvers[n].solve(patch);
        const rec = glyphPatchReconstruction(w, h, rec_colors, glyphs[n]);
        const rec_diff = patchDiff(w, h, rec, patch);
        best_n = if (rec_diff < best_diff) n else best_n;
        best_diff = @min(rec_diff, best_diff);
    }

    // faster to recompute once than call N conditional moves
    var pixel = glyph_color_solvers[best_n].solve(patch);
    pixel.codepoint_hex = codepoints[best_n];
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

        pub fn solve(self: GlyphColorSolver(w, h), patch: image_patch.ImagePatch(w, h)) unicode_image.UnicodePixelData {
            const r = self.solveChannel(patch.r);
            const g = self.solveChannel(patch.g);
            const b = self.solveChannel(patch.b);
            return .{ .br = r.C_b, .bg = g.C_b, .bb = b.C_b, .fr = r.C_f, .fg = g.C_f, .fb = b.C_f, .codepoint_hex = undefined};
        }

        fn solveChannel(self: GlyphColorSolver(w, h), patch: @Vector(w*h, u8)) struct { C_b: u8, C_f: u8 } {
            const P: @Vector(w*h, f32) = @floatFromInt(patch);
            const C_b_num = @reduce(.Add, P * self.B) * self.FF - @reduce(.Add, P * self.F) * self.BF;
            const C_f_num = @reduce(.Add, P * self.F) * self.BB - @reduce(.Add, P * self.B) * self.BF;
            const C_b = std.math.clamp(C_b_num / self.det, 0, 255);
            const C_f = std.math.clamp(C_f_num / self.det, 0, 255);
            return .{ .C_b = @intFromFloat(C_b), .C_f = @intFromFloat(C_f) };
        }
    };
}

pub fn glyphPatchReconstruction(
    comptime w: u8,
    comptime h: u8,
    colors: unicode_image.UnicodePixelData,
    g: glyph.GlyphPixmap(w, h)
) image_patch.ImagePatch(w, h) {
    const r_rec = @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.br))) * g.pixmap_neg
                + @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.fr))) * g.pixmap_pos;
    const g_rec = @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.bg))) * g.pixmap_neg
                + @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.fg))) * g.pixmap_pos;
    const b_rec = @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.bg))) * g.pixmap_neg
                + @as(@Vector(w*h, f32), @splat(@floatFromInt(colors.fg))) * g.pixmap_pos;
    return .{ .r = @intFromFloat(r_rec), .g = @intFromFloat(g_rec), .b = @intFromFloat(b_rec) };
}

pub fn patchDiff(comptime w: u8, comptime h: u8, a: image_patch.ImagePatch(w, h), b: image_patch.ImagePatch(w, h)) u16 {
    // abs difference via saturation subtraction, and promote to u16 for future reduce operation
    const r_diff: @Vector(w*h, u16) = (a.r -| b.r) | (b.r -| a.r);
    const g_diff: @Vector(w*h, u16) = (a.g -| b.g) | (b.g -| a.g);
    const b_diff: @Vector(w*h, u16) = (a.b -| b.b) | (b.b -| a.b);
    return @reduce(.Add, r_diff + g_diff + b_diff);
}

