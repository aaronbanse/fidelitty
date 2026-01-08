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
    const dims = terminal.getDims();
    try im.init(&allocator, dims.cols, dims.rows);
    defer im.deinit(&allocator);

    var i: u16 = 0;
    var j: u16 = 0;
    while (j < dims.rows) : (j += 1) {
        i = 0;
        while (i < dims.cols) : (i += 1) {
            try im.writePixel(splat_pix, i, j);
        }
    }

    _ = try std.posix.write(1, "\n\n");
    i = 0;
    while (i < 600) : (i+=1) {
        _ = try std.posix.write(1, im.buf);
    }
}

