const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const mem = std.mem;
const fmt = std.fmt;
const debug = std.debug;

pub fn getCursorPos() !struct { row: u16, col: u16 } {
    const stdin = fs.File.stdin();
    const stdout = fs.File.stdout();
    
    // Save original termios and switch to raw mode
    const orig = try posix.tcgetattr(stdin.handle);
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    try posix.tcsetattr(stdin.handle, .FLUSH, raw);
    defer posix.tcsetattr(stdin.handle, .FLUSH, orig) catch {};

    // Send DSR query
    try stdout.writeAll("\x1b[6n");

    // Read response: \x1b[row;colR
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = try stdin.read(buf[len .. len + 1]);
        if (n == 0) break;
        if (buf[len] == 'R') break;
        len += 1;
    }

    // Parse "\x1b[row;col"
    const resp = buf[0..len];
    if (resp.len < 3 or resp[0] != '\x1b' or resp[1] != '[') return error.InvalidResponse;
    
    const nums = resp[2..];
    const semi = mem.indexOf(u8, nums, ";") orelse return error.InvalidResponse;
    
    const row = try fmt.parseInt(u16, nums[0..semi], 10);
    const col = try fmt.parseInt(u16, nums[semi + 1 ..], 10);
    
    return .{ .row = row-1, .col = col-1 }; // convert back to 0-indexed
}

pub fn getDims() struct { cols: u16, rows: u16, cell_w: u16, cell_h: u16 } {
    var wsz: posix.winsize = undefined;
    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&wsz));

    if (rc != 0) {
        debug.print("Error: ioctl failed with code {}", .{rc});
        return .{ .cols = 0, .rows = 0, .cell_w = 0, .cell_h = 0 };
    }

    return .{
        .cols = wsz.col,
        .rows = wsz.row,
        .cell_w = wsz.xpixel / wsz.col,
        .cell_h = wsz.ypixel / wsz.row,
    };
}

pub fn reserveVerticalSpace(rows: u16) !void {
    const MOVE_CURSOR_UP_TEMPLATE = "\x1b[{d}A";
    const stdout = std.fs.File.stdout();

    for (0..rows) |_| {
        try stdout.writeAll("\n");
    }

    var move_cursor_buf: [16]u8 = undefined;
    const move_cursor_up = try fmt.bufPrint(&move_cursor_buf, MOVE_CURSOR_UP_TEMPLATE, .{rows});

    try stdout.writeAll(move_cursor_up);
}

