const std = @import("std");
const image = @import("image.zig");
const terminal = @import("terminal.zig");
const glyph = @import("glyph.zig");

pub fn main() !void {
    // get allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    //
    // // initialize image to terminal dims
    // var im: image.UnicodeImage = undefined;
    // const dims = terminal.getDims();
    // try im.init(alloc.allocator(), dims.cols, dims.rows);
    // defer im.deinit(alloc.allocator());
    //
    // const splat_pix: image.UnicodePixelData = .{
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
    // var i: u16 = 0;
    // while (i < 300) : (i+=1) {
    //     var k: u16 = 0;
    //     while (k < dims.rows) : (k += 1) {
    //         var j: u16 = 0;
    //         while (j < dims.cols) : (j += 1) {
    //             try im.writePixel(splat_pix, j, k);
    //         }
    //     }
    //     _ = try std.posix.write(1, im.buf);
    // }

    const bitmap_generator: glyph.BitmapGenerator = try .init(allocator, "FiraCodeNerdFont-Regular.ttf");
    defer bitmap_generator.deinit(allocator);

    const glyph_bitmap: glyph.GlyphBitmap(16,32) = .generate(0x2800, &bitmap_generator);
    glyph_bitmap.print();
}

