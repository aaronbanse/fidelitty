const std = @import("std");
const image_patch = @import("image_patch.zig");
const debug = @import("debug.zig");
const glyph = @import("glyph.zig");
const algo = @import("algo.zig");
const unicode_image = @import("unicode_image.zig");
const terminal = @import("terminal.zig");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // load image
    var img_w: u32 = undefined;
    var img_h: u32 = undefined;
    var img_chan_n: u32 = undefined;
    const image_raw: *u8 = c.stbi_load("/home/acbanse/Projects/fidelitty/.img/IMG_3706.JPEG", @ptrCast(&img_w), @ptrCast(&img_h), @ptrCast(&img_chan_n), 3);
    defer c.stbi_image_free(image_raw);
    
    // setup dimensions
    const term_dims = terminal.getDims();
    const w = 4; // patch width
    const h = 4; // patch height

    // init output image
    var out_image: unicode_image.UnicodeImage = undefined;
    try out_image.init(allocator, 0, 0, term_dims.cols, term_dims.rows);
    defer out_image.deinit(allocator);

    // sample patches
    var patches: []image_patch.ImagePatch(w,h) = try allocator.alloc(image_patch.ImagePatch(w,h), term_dims.cols * term_dims.rows);
    defer allocator.free(patches);
    for (0..term_dims.rows) |y| {
        for (0..term_dims.cols) |x| {
            patches[y * term_dims.cols + x].sample(@ptrCast(image_raw), @intCast(img_w), @intCast(img_h),
                term_dims.cols, term_dims.rows, @intCast(x), @intCast(y));
        }
    }

    // get codepoints
    const u8_vals: u16 = std.math.maxInt(u8) + 1; // num vals u8 can take
    var codepoints: [u8_vals*2]u16 = undefined;
    for (0..u8_vals) |n| {
        codepoints[n] = 0x2800 + @as(u16, @intCast(n));
        if (n == 0x91 or n == 0x92 or n == 0x93) {
            codepoints[n+u8_vals] = 0x2500;
        } else {
            codepoints[n+u8_vals] = 0x2500 + @as(u16, @intCast(n));
        }
    }

    // get pixmaps
    const pixmap_generator: glyph.PixmapGenerator = try .init(allocator, "Adwaita/AdwaitaMono-Regular.ttf");
    defer pixmap_generator.deinit(allocator);

    const glyphs = try glyph.getGlyphPixmapSet(w, h, &codepoints, &pixmap_generator, allocator);
    defer allocator.free(glyphs);

    // precompute glyph color solvers
    var solvers: [codepoints.len]algo.GlyphColorSolver(w,h) = undefined;
    for (0..codepoints.len) |n| {
        solvers[n] = algo.glyphColorSolver(w, h, glyphs[n]);
    }
        // write pixels to image
    for (0..term_dims.rows) |y| {
        for (0..term_dims.cols) |x| {
            const pixel = algo.computePixel(w, h, patches[y * term_dims.cols + x], &codepoints, glyphs, &solvers);
            out_image.writePixel(pixel, @intCast(x), @intCast(y));
        }
    }

    _ = try std.posix.write(1, out_image.buf);
}

