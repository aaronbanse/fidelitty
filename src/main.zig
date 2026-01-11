const std = @import("std");
const image_patch = @import("image_patch.zig");
const debug = @import("debug.zig");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub fn main() !void {
    // var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    // defer _ = debug_allocator.deinit();
    // const allocator = debug_allocator.allocator();

    // load image
    var img_w: u32 = undefined;
    var img_h: u32 = undefined;
    var img_chan_n: u32 = undefined;
    const image_raw: *u8 = c.stbi_load("/home/acbanse/Projects/fidelitty/.img/IMG_3706.JPEG", @ptrCast(&img_w), @ptrCast(&img_h), @ptrCast(&img_chan_n), 3);
    defer c.stbi_image_free(image_raw);
    
    // sample patch
    const patch_w: u16 = 32;
    const patch_h: u16 = 32;
    var patch: image_patch.ImagePatch(patch_w, patch_h) = undefined;
    patch.sample(@ptrCast(image_raw), @intCast(img_w), @intCast(img_h), 2, 2, 0, 0);

    try debug.renderImagePatch(patch_w, patch_h, &patch);
}



//-----------------------------------------------------------

// // sample patch
//     const term_w = 160;
//     const term_h = 51;
//     const patch_w = 4;
//     const patch_h = 4;
//     const patches: [term_w*term_h]image_patch.ImagePatch(patch_w,patch_h) = undefined;
//     for (0..term_h) |y| {
//         for (0..term_w) |x| {
//             patches[y*term_w + x].sample(@ptrCast(image), @intCast(img_w), @intCast(img_h), term_w, term_h, x, y);
//         }
//     }
//     // get codepoints
//     const u8_vals: u16 = @as(comptime_int, 1) << @typeInfo(u8).int.bits;
//     var box_drawing_codepoints: [u8_vals]u16 = undefined;
//     for (0..u8_vals) |n| {
//         box_drawing_codepoints[n] = 0x2500 + @as(u16, @intCast(n));
//     }
//
//     // get pixmaps
//     const pixmap_generator: glyph.PixmapGenerator = try .init(allocator, "Adwaita/AdwaitaMono-Regular.ttf");
//     defer pixmap_generator.deinit(allocator);
//
//     const box_drawing_glyphs = try glyph.getGlyphPixmapSet(&box_drawing_codepoints, 4, 4, &pixmap_generator, allocator);
//     defer allocator.free(box_drawing_glyphs);
//
//     // setup buffer for unicode pixel encodings
//
//     // generate image for patch
//     var out_image: unicode_image.UnicodeImage = undefined;
//     try out_image.init(allocator, 160, 51);
//     defer out_image.deinit(allocator);
//
//     // transform patches to pixel encodings
//
//     // write all pixel encodings
//
//     std.posix.write(1, out_image.buf);
//
//
//
//  // const bitmap_generator: glyph.BitmapGenerator = try .init(allocator, "Adwaita/AdwaitaMono-Regular.ttf");
    // defer bitmap_generator.deinit(allocator);

    // const glyph_bitmap: glyph.GlyphBitmap(2,4) = .generate(0x2835, &bitmap_generator);
    // glyph_bitmap.print();



    // // initialize image to terminal dims
    // var im: unicode_image.UnicodeImage = undefined;
    // const dims = terminal.getDims();
    // try im.init(alloc.allocator(), dims.cols, dims.rows);
    // defer im.deinit(alloc.allocator());
    //
    // const splat_pix: unicode_image.UnicodePixelData = .{
    //     .br=0,
    //     .bg=16,
    //     .bb=255,
    //     .fr=38,
    //     .fg=160,
    //     .fb=0,
    //     .codepoint_hex=0x257f,
    // };
    //
    // _ = try std.posix.write(1, "\n\n");
    // for (0..300) |i| {
    //     for (0..dims.rows) |k| {
    //         for (0..dims.cols) |j| {
    //             try im.writePixel(splat_pix, j, k);
    //         }
    //     }
    //     _ = try std.posix.write(1, im.buf);
    // }

