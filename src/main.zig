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
    const image_raw: [*]u8 = c.stbi_load("/home/acbanse/Projects/fidelitty/.img/IMG_3706.JPEG", @ptrCast(&img_w), @ptrCast(&img_h), @ptrCast(&img_chan_n), 3);
    defer c.stbi_image_free(image_raw);

    // TEMP: will delete----------
    const image_flipped: []u8 = try allocator.alloc(u8, img_w * img_h * 3);
    defer allocator.free(image_flipped);
    for (0..img_h) |y| {
        for (0..img_w) |x| {
            for (0..3) |chan| {
                const idx = img_w * y + x;
                const idx_flipped = (img_w * img_h) - idx - 1;
                image_flipped[idx*3 + chan] = image_raw[idx_flipped*3 + chan];
            }
        }
    }
    // END TEMP-------------------

    // setup dimensions
    const term_dims = terminal.getDims();
    const w = 4; // patch width
    const h = 4; // patch height
    const out_image_h: u16 = term_dims.rows;
    const out_image_w: u16 = @intFromFloat(@as(f32, @floatFromInt(term_dims.rows * term_dims.cell_h)) // new_h
        * (@as(f32, @floatFromInt(img_w)) / @as(f32, @floatFromInt(img_h))) / @as(f32, @floatFromInt(term_dims.cell_w))); // old_w / old_h

    // init output image
    var out_image: unicode_image.UnicodeImage = undefined;
    try out_image.init(allocator, 0, 0, out_image_w, out_image_h);
    defer out_image.deinit(allocator);

    // sample patches
    var patches: []image_patch.ImagePatch(w,h) = try allocator.alloc(image_patch.ImagePatch(w,h), out_image_w * out_image_h);
    defer allocator.free(patches);
    for (0..out_image_h) |y| {
        for (0..out_image_w) |x| {
            patches[y * out_image_w + x].sample(image_flipped, @intCast(img_w), @intCast(img_h),
                out_image_w, out_image_h, @intCast(x), @intCast(y));
        }
    }

    // get codepoints
    const u8_vals: u16 = std.math.maxInt(u8) + 1; // num vals u8 can take
    var codepoints: [u8_vals*2]u32 = undefined;
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
    for (0..out_image_h) |y| {
        for (0..out_image_w) |x| {
            const pixel = algo.computePixel(w, h, patches[y * out_image_w + x], &codepoints, glyphs, &solvers);
            out_image.writePixel(pixel, @intCast(x), @intCast(y));
        }
    }

    _ = try std.posix.write(1, out_image.buf);
}

