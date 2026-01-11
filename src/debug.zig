const std = @import("std");
const unicode_image = @import("unicode_image.zig");
const image_patch = @import("image_patch.zig");
const terminal = @import("terminal.zig");

pub fn renderImagePatch(comptime w: u16, comptime h: u16, im: *const image_patch.ImagePatch(w, h)) !void {
    // init allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const alloc = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    // init out image
    var out_image: unicode_image.UnicodeImage = undefined;
    const cursor_pos = try terminal.getCursorPos();
    try out_image.init(alloc, cursor_pos.col, cursor_pos.row, w, h);
    defer out_image.deinit(alloc);

    // write patch pixels as unicode pixels
    im.render(&out_image);

    _ = try std.posix.write(1, out_image.buf);
    // std.debug.print("{f}\n", .{std.ascii.hexEscape(out_image.buf, .lower)});
}

