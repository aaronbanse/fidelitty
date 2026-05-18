const std = @import("std");
const metrics = @import("font/metrics.zig");
const writer = @import("font/writer.zig");

pub fn initFont(
    io: std.Io,
    allocator: std.mem.Allocator,
    user_font_path: []const u8,
    user_home_dir: []const u8,
) !void {
    const user_font_metrics = try metrics.getFontMetrics(io, user_font_path);
    try writer.generateFromMetrics(io, allocator, user_font_metrics, user_home_dir);
}
