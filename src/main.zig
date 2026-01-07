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
        .codepoint_hex=0x2580,
    };

    var pix_buf = [_]u8{undefined} ** pix.WORD_SIZE;
    _=pix.getTemplateStringBuf(&pix_buf);
    _=pixel.print(&pix_buf);

    const writer = std.fs.File.stdout();
    try writer.writeAll(&pix_buf);
}

