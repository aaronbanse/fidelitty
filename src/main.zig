//! Generates a Fidelitty glyph-set OpenType font from a user-supplied font.

const std = @import("std");
const ftty = @import("fidelitty");

fn cmdInit(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    user_home_dir_path: []const u8,
) !void {
    const user_font_path = args[1];
    const installed_path = try ftty.initFont(io, allocator, user_font_path, user_home_dir_path);
    defer allocator.free(installed_path);

    // A terminal caches its font set (and per-codepoint glyph lookups) at
    // startup, so it won't pick up the freshly installed glyph set until
    // fontconfig's cache is refreshed and the terminal is restarted.
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const stderr = &stderr_writer.interface;
    try stderr.print(
        "Font installed to {s}\n" ++
            "Run `fc-cache -f` then restart your terminal for the font to be discovered.\n",
        .{installed_path},
    );
    try stderr.flush();
}

pub fn main(init: std.process.Init) !void {
    var arena_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();
    const io = init.io;
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        try stderr.writeAll("usage: ftty-init <user_font_path>\n");
        std.process.exit(1);
    }
    const home_dir = init.environ_map.get("HOME") orelse {
        std.log.err("no home dir", .{});
        std.process.exit(1);
    };
    try cmdInit(io, arena, args, home_dir);
}
