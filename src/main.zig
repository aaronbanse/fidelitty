//! Generates a Fidelitty glyph-set OpenType font from a user-supplied font.

// fc-match --format='%{file}\n'

const std = @import("std");
const ftty = @import("fidelitty");

fn cmdInit(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    user_home_dir: []const u8,
) !void {
    const root = std.Progress.start(io, .{ .root_name = "Init" });
    defer root.end();

    const user_font_path = args[2];
    const gen_node = root.start("Generate fidelitty rendering font", 1);
    try ftty.initFont(io, allocator, user_font_path, user_home_dir);
    gen_node.end();
}

// Purpose: not sure yet. Something like ffmpeg's interface.
fn cmdCompute(io: std.Io, args: []const [:0]const u8) !void {
    _=io;
    _=args;
    return error.NotImplemented;
    // stub for now
}

pub fn main(init: std.process.Init) !void {
    var arena_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();
    const io = init.io;
    var buf: [256]u8 = undefined;
    const stderr_writer = std.Io.File.stderr().writer(io, &buf);
    var stderr = stderr_writer.interface;

    const usage_str = "usage: ftty <init|compute> <args...>\n";

    // TODO: should prob handle errors directly instead of surfacing them to the user.
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try stderr.writeAll(usage_str);
        return error.MissingCommand;
    }

    if (std.mem.eql(u8, args[1], "init")) {
        const home_dir = init.environ_map.get("HOME") orelse return error.NoHomeDir;
        return try cmdInit(io, arena, args, home_dir);
    } else if (std.mem.eql(u8, args[1], "compute")) {
        return try cmdCompute(io, args);
    } else {
        try stderr.writeAll(usage_str);
        return error.InvalidCommand;
    }
}
