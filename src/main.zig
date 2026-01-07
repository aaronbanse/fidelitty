const std = @import("std");
const image = @import("image.zig");
const terminal = @import("terminal.zig");

pub fn main() !void {
    const splat_pix: image.UnicodePixelData = .{
        .br=0,
        .bg=16,
        .bb=255,
        .fr=38,
        .fg=160,
        .fb=0,
        .codepoint_hex=0x2584,
    };

    var im: image.UnicodeImage = undefined;
    const allocator = std.heap.page_allocator;
    const dims = terminal.getSize();
    try im.init(&allocator, dims.cols, dims.rows);

    var i: u16 = 0;
    var j: u16 = 0;
    while (j < dims.rows) : (j += 1) {
        i = 0;
        while (i < dims.cols) : (i += 1) {
            try splat_pix.print(im.getPixel(i, j));
        }
    }

    const writer = std.fs.File.stdout();

    try writer.writeAll(im.data);
}

