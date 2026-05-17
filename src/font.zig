const std = @import("std");
const metrics = @import("font/metrics.zig");
const writer = @import("font/writer.zig");

pub fn initFont(io: std.Io, user_font_path: []const u8) !void {
    const user_font_metrics = try metrics.getFontMetrics(io, user_font_path);
    try writer.generateFromMetrics(io, user_font_metrics);
}
