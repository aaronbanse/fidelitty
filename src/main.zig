const std = @import("std");
const px = @import("unicode_pixel.zig");
const _ = @import("unicode_image.zig");

pub fn main() !void {
    const pixel: px.UnicodePixel = .{
        .br=0,
        .bg=16,
        .bb=255,
        .fr=38,
        .fg=160,
        .fb=0,
        .char=.{0,37,128},
    };

    var pix_buf = [_]u8{undefined} ** px.WORD_SIZE;
    _=px.getTemplateStringBuf(&pix_buf);
    _=pixel.print(&pix_buf);

    std.debug.print("{s}", .{pix_buf});
}

