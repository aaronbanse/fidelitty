const std = @import("std");
const unicode_image = @import("unicode_image.zig");
const image_patch = @import("image_patch.zig");
const terminal = @import("terminal.zig");
const glyph = @import("glyph.zig");

pub const Options = struct {
    appearance: Appearance = .normal,

    pub const Appearance = enum { normal, escaped };
};

pub fn renderImagePatch(comptime w: u8, comptime h: u8, im: image_patch.ImagePatch(w, h), options: Options) !void {
    const Closure = struct {
        im: image_patch.ImagePatch(w, h),
        fn get_colors(self: @This(), x: u16, y: u16) struct {r: u8, g: u8, b: u8} {
            const idx = y * w + x;
            return .{ .r = self.im.r[idx], .g = self.im.g[idx], .b = self.im.b[idx] };
        }
    };
    try renderGeneric(w, h, Closure{ .im = im }, options);
}

pub fn renderVectorsRGB(comptime w: u8, comptime h: u8, r: @Vector(w*h, u8), g: @Vector(w*h, u8), b: @Vector(w*h, u8), options: Options) !void {
    const Closure = struct {
        r: @Vector(w*h, u8),
        g: @Vector(w*h, u8),
        b: @Vector(w*h, u8),
        fn get_colors(self: @This(), x: u16, y: u16) struct {r: u8, g: u8, b: u8} {
            const idx = y * w + x;
            return .{ .r = self.r[idx], .g = self.g[idx], .b = self.b[idx] };
        }
    };
    try renderGeneric(w, h, Closure{ .r = r, .g = g, .b = b }, options);
}

pub fn renderVector(comptime w: u8, comptime h: u8, vec: @Vector(w*h, u8), options: Options) !void {
    const Closure = struct {
        vec: @Vector(w * h, u8),
        fn get_colors(self: @This(), x: u16, y: u16) struct {r: u8, g: u8, b: u8} {
            const idx = y * w + x;
            return .{ .r = self.vec[idx], .g = self.vec[idx], .b = self.vec[idx] };
        }
    };
    try renderGeneric(w, h, Closure{ .vec = vec }, options);
}

pub fn renderGlyphPixmap(comptime w: u8, comptime h: u8, pixmap: glyph.GlyphPixmap(w, h), options: Options) !void {
    const Closure = struct {
        pos_map: @Vector(w*h, u8),
        fn get_colors(self: @This(), x: u16, y: u16) struct {r: u8, g: u8, b: u8} {
            const idx = y * w + x;
            return .{ .r = self.pos_map[idx], .g = self.pos_map[idx], .b = self.pos_map[idx] };
        }
    };
    try renderGeneric(w, h, Closure{ .pos_map = @intFromFloat(@as(@Vector(w*h, f32), @splat(255)) * pixmap.pixmap_pos) }, options);
}

fn renderGeneric(w: u8, h: u8, get_color_closure: anytype, options: Options) !void {
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
    for (0..h) |y| {
        for (0..w) |x| {
            const c = get_color_closure.get_colors(@intCast(x), @intCast(y));
            out_image.writePixelColor(c.r, c.g, c.b, @intCast(x), @intCast(y));
        }
    }

    // print normally or escaped to view internals
    if (options.appearance == .escaped) {
        std.debug.print("{f}", .{std.ascii.hexEscape(out_image.buf, .lower)});
    } else if (options.appearance == .normal) {
        _ = try std.posix.write(1, out_image.buf);
    }
    std.debug.print("\n\n", .{});
}

