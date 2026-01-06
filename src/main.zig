const std = @import("std");
const pix = @import("pixel.zig");
const image = @import("image.zig");

pub fn main() !void {
    const pixel: pix.UnicodePixel = .{
        .br=0,
        .bg=16,
        .bb=255,
        .fr=38,
        .fg=160,
        .fb=0,
        .char=.{0,37,128},
    };

    var pix_buf = [_]u8{undefined} ** pix.WORD_SIZE;
    _=pix.getTemplateStringBuf(&pix_buf);
    _=pixel.print(&pix_buf);

    std.debug.print("{s}", .{pix_buf});
}

