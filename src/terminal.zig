const std = @import("std");
const posix = std.posix;

pub fn getDims() struct { cols: u16, rows: u16 } {
    var wsz: posix.winsize = undefined;
    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&wsz));

    if (rc != 0) {
        std.debug.print("Error: ioctl failed with code {}", .{rc});
        return .{ .cols = 0, .rows = 0 };
    }

    return .{ .cols = wsz.col, .rows = wsz.row };
}

