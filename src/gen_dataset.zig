const std = @import("std");
const heap = std.heap;
const fs = std.fs;
const mem = std.mem;

const config = @import("config");

const glyph = @import("glyph.zig");

pub fn main() !void {
    // Configuration
    const patch_w = config.patch_width;
    const patch_h = config.patch_height;
    const charset_size = config.charset_size;
    const dataset_path = config.dataset_path;

    // Allocator
    var debug_allocator: heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const charset_path = args[1];

    // Open file containing all characters to use for the dataset
    var read_file = try fs.cwd().openFile(charset_path, .{ .mode = .read_only, });
    defer read_file.close();

    // deserialize character set
    var codepoints: [charset_size]u32 = undefined;
    var read_buf: [1024]u8 = undefined;
    var reader = read_file.reader(&read_buf);
    try reader.interface.readSliceAll(mem.asBytes(&codepoints));

    // Generate dataset
    var dataset: glyph.UnicodeGlyphDataset(patch_w, patch_h, charset_size) = undefined;
    try dataset.init(&codepoints, allocator);

    // Open file to write dataset to
    var write_file = try fs.cwd().createFile(dataset_path, .{});
    defer write_file.close();

    // Serialize data of unicode glyph dataset as raw bytes - will deserialize at runtime
    var write_buf: [1024]u8 = undefined;
    var writer = write_file.writer(&write_buf);
    try writer.interface.writeAll(mem.asBytes(&dataset));
    try writer.interface.flush(); // don't forget to flush!
}

