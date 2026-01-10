const std = @import("std");
const unicode_image = @import("unicode_image.zig");
const image_patch = @import("image_patch.zig");
const terminal = @import("terminal.zig");
const glyph = @import("glyph.zig");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // load image
    var x: u32 = undefined;
    var y: u32 = undefined;
    var n: u32 = undefined;
    const image: *u8 = c.stbi_load("/home/acbanse/Projects/fidelitty/.img/IMG_3706.JPEG", @ptrCast(&x), @ptrCast(&y), @ptrCast(&n), 3);
    defer c.stbi_image_free(image);

    // sample patch
    const w: u16 = 4;
    const h: u16 = 8;
    var patch: image_patch.ImagePatch(w, h) = undefined;
    patch.sample(@ptrCast(image), @intCast(x), @intCast(y), 5, 5, 1, 3);

    // generate image for patch
    var patch_unicode_image: unicode_image.UnicodeImage = undefined;
    try patch_unicode_image.init(allocator, w, h);
    defer patch_unicode_image.deinit(allocator);

    // render
    try patch.render(&patch_unicode_image);
    _ = try std.posix.write(1, patch_unicode_image.buf);
}



//-----------------------------------------------------------
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

