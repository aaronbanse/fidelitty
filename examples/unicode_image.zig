//! Experimental terminal frontend: a ready-to-print grid of colored unicode
//! characters. Lives in examples/ rather than the library — most applications
//! will feed the pipeline's output into their own rendering instead.

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const unicode = std.unicode;
const Io = std.Io;

const UnicodePixelData = @import("fidelitty").UnicodePixelData;

// escape sequence to set the background color and foreground color for future printed characters,
// plus four null bytes of space reserved for a single unicode character.
// Unused space is "padded" with null bytes so as not to print extra characters to the terminal.
const PIXEL_STR_TEMPLATE: *const [42:0]u8 = "\x1b[48;2;000;000;000m\x1b[38;2;000;000;000m\x00\x00\x00\x00";

// auxiliary escape sequences for image positioning and syncing
const BEGIN_SYNC_SEQ = "\x1b[?2026h"; // begin synced output and reset cursor position
const END_SYNC_SEQ = "\x1b[?2026l"; // end synced output
const SET_CURSOR_SEQ_TEMPLATE = "\x1b[000;000H"; // fill in 0s to set cursor position. NOTE: 1-INDEXED!!

pub const UnicodeImage = struct {
    x: u16,
    y: u16,
    grid_w: u16,
    grid_h: u16,
    buf: []u8,

    pub fn init(alloc: mem.Allocator, grid_w: u16, grid_h: u16) !@This() {
        var img: @This() = undefined;

        img.buf = try alloc.alloc(u8, getSize(grid_w, grid_h));
        img.x = 0;
        img.y = 0;
        img.grid_w = grid_w;
        img.grid_h = grid_h;
        img.fillTemplate();
        img.writeRowPositions();

        return img;
    }

    pub fn resize(self: *@This(), alloc: mem.Allocator, grid_w: u16, grid_h: u16) !void {
        self.buf = try alloc.realloc(self.buf, getSize(grid_w, grid_h));
        self.grid_w = grid_w;
        self.grid_h = grid_h;
        self.fillTemplate();
        self.writeRowPositions();
    }

    pub fn deinit(self: *@This(), alloc: mem.Allocator) void {
        self.grid_w = 0;
        self.grid_h = 0;
        alloc.free(self.buf);
    }

    pub fn setPos(self: *@This(), x: u16, y: u16) void {
        if (self.x == x and self.y == y) return;
        self.x = x;
        self.y = y;
        self.writeRowPositions();
    }

    // unsafe, assumes pixel buf and image are same dimensions
    pub fn readPixels(self: @This(), pixels: [*]UnicodePixelData) void {
        self.readPixelsRegion(pixels, 0, 0, self.grid_w, self.grid_h);
    }

    pub fn readPixelsRegion(self: @This(), pixels: [*]UnicodePixelData, rx: u16, ry: u16, rw: u16, rh: u16) void {
        for (0..rh) |i| {
            const y: u16 = ry + @as(u16, @intCast(i));
            for (0..rw) |j| {
                const x: u16 = rx + @as(u16, @intCast(j));
                self.writePixel(pixels[y * self.grid_w + x], x, y);
            }
        }
    }

    pub fn draw(self: @This(), io: Io) !void {
        const stdout = std.Io.File.stdout();
        _ = try stdout.writeStreamingAll(io, self.buf);
    }

    /// Dump raw pixel data from the internal buffer to stderr for debugging.
    /// Prints row, col, bg/fg rgb, and the raw utf-8 bytes for each pixel.
    pub fn dumpRaw(self: @This()) void {
        for (0..self.grid_h) |row| {
            for (0..self.grid_w) |col| {
                const pix_index = BEGIN_SYNC_SEQ.len
                    + row * getRowSize(self.grid_w)
                    + SET_CURSOR_SEQ_TEMPLATE.len
                    + col * PIXEL_STR_TEMPLATE.len;
                const pixel = self.buf[pix_index..][0..PIXEL_STR_TEMPLATE.len];
                std.debug.print("{d},{d} bg=({s},{s},{s}) fg=({s},{s},{s}) utf8={X:0>2} {X:0>2} {X:0>2} {X:0>2}\n", .{
                    row, col,
                    pixel[7..10], pixel[11..14], pixel[15..18],
                    pixel[26..29], pixel[30..33], pixel[34..37],
                    pixel[38], pixel[39], pixel[40], pixel[41],
                });
            }
        }
    }

    pub fn drawRegion(self: @This(), io: Io, rx: u16, ry: u16, rw: u16, rh: u16) !void {
        const stdout = std.Io.File.stdout();
        _ = try stdout.writeStreamingAll(io, BEGIN_SYNC_SEQ);
        var cursor_buf: [SET_CURSOR_SEQ_TEMPLATE.len]u8 = undefined;
        @memcpy(&cursor_buf, SET_CURSOR_SEQ_TEMPLATE);
        for (0..rh) |i| {
            const y: u16 = ry + @as(u16, @intCast(i));
            // write cursor position for this row
            _ = std.fmt.printInt(cursor_buf[2..], self.y + y + 1, 10, .lower, .{ .fill = 48, .width = 3 });
            _ = std.fmt.printInt(cursor_buf[6..], self.x + rx + 1, 10, .lower, .{ .fill = 48, .width = 3 });
            _ = try stdout.writeStreamingAll(io, &cursor_buf);
            // write pixel data for columns [rx, rx+rw)
            const row_start = BEGIN_SYNC_SEQ.len + @as(usize, y) * getRowSize(self.grid_w);
            const pixels_start = row_start + SET_CURSOR_SEQ_TEMPLATE.len + @as(usize, rx) * PIXEL_STR_TEMPLATE.len;
            const pixels_end = pixels_start + @as(usize, rw) * PIXEL_STR_TEMPLATE.len;
            _ = try stdout.writeStreamingAll(io, self.buf[pixels_start..pixels_end]);
        }
        _ = try stdout.writeStreamingAll(io, END_SYNC_SEQ);
    }

    fn writePixel(self: @This(), data: UnicodePixelData, x: u16, y: u16) void {
        const row_start_idx = BEGIN_SYNC_SEQ.len + y * getRowSize(self.grid_w);
        const pix_index = row_start_idx + SET_CURSOR_SEQ_TEMPLATE.len + x * PIXEL_STR_TEMPLATE.len;
        u8ToString(data.br, self.buf[pix_index + 7..]); // background colors
        u8ToString(data.bg, self.buf[pix_index + 11..]);
        u8ToString(data.bb, self.buf[pix_index + 15..]);
        u8ToString(data.fr, self.buf[pix_index + 26..]); // foreground colors
        u8ToString(data.fg, self.buf[pix_index + 30..]);
        u8ToString(data.fb, self.buf[pix_index + 34..]);

        // encode utf8
        _ = unicode.utf8Encode(@intCast(data.codepoint), self.buf[pix_index+38..]) catch {
            self.buf[pix_index+38] = 48;// 0
        };
    }

    /// Fills a template for the image with it's size and position fixed.
    /// This consists of:
    /// 1. "begin sync" esc seq, telling terminal to print all out at once.
    /// 2. For each row, a "set cursor pos" esc seq and a set of escape sequence templates (colors/codepoint not set) for each colored unicode char.
    /// 3. "end sync" esc seq, signalling end of synced output.
    fn fillTemplate(self: *@This()) void {
        _=fmt.bufPrint(self.buf, BEGIN_SYNC_SEQ, .{}) catch {};

        for (0..self.grid_h) |row| {
            const row_start_idx = BEGIN_SYNC_SEQ.len + row * getRowSize(self.grid_w);

            // Fill escape sequence for setting cursor pos
            _=std.fmt.bufPrint(self.buf[row_start_idx..], SET_CURSOR_SEQ_TEMPLATE, .{}) catch {};
            const row_pixels_start_idx = row_start_idx + SET_CURSOR_SEQ_TEMPLATE.len;

            for (0..self.grid_w) |col| {
                // print empty pixel string template
                const pix_index = row_pixels_start_idx + col * PIXEL_STR_TEMPLATE.len;
                _=fmt.bufPrint(self.buf[pix_index..], PIXEL_STR_TEMPLATE, .{}) catch {};
            }
        }

        _=fmt.bufPrint(self.buf[self.buf.len - END_SYNC_SEQ.len..], END_SYNC_SEQ, .{}) catch {};
    }

    fn writeRowPositions(self: *@This()) void {
        for (0..self.grid_h) |row| {
            const row_start_idx = BEGIN_SYNC_SEQ.len + row * getRowSize(self.grid_w);
            // don't use u8ToString here as resizing doesn't need to be performant, and x,y go up to 998
            _=std.fmt.printInt(self.buf[row_start_idx + 2 ..], self.y + row + 1, 10, .lower, .{.fill = 48, .width = 3});
            _=std.fmt.printInt(self.buf[row_start_idx + 6 ..], self.x + 1, 10, .lower, .{.fill = 48, .width = 3});
        }
    }

    fn getRowSize(grid_w: u16) usize {
        return @as(usize, grid_w) * PIXEL_STR_TEMPLATE.len + SET_CURSOR_SEQ_TEMPLATE.len;
    }

    fn getSize(grid_w: u16, grid_h: u16) usize {
        return @as(usize, BEGIN_SYNC_SEQ.len + END_SYNC_SEQ.len) + getRowSize(grid_w) * grid_h;
    }
};

// Converts a u8 (0-255) to a 0-padded string of length 3
fn u8ToString(n: u8, buf: []u8) void {
    // Magic numbers for optimized division.
    // Approximate 1/N as M/(2^k), so we can multiply by M and bit shift right by k.
    const DIV_10_M: u16 = 205;
    const DIV_10_SHIFT: u16 = 11;
    const DIV_100_M: u16 = 41;
    const DIV_100_SHIFT: u16 = 12;
    // int to char conversion
    const CHAR_0_OFFSET: u8 = 48;

    const hundreds: u8 = @intCast((@as(u16, n) * DIV_100_M) >> DIV_100_SHIFT);
    const mod_hundred: u8 = n - (hundreds * 100);
    const tens: u8 = @intCast((@as(u16, mod_hundred) * DIV_10_M) >> DIV_10_SHIFT);
    const ones: u8 = mod_hundred - (tens * 10);
    buf[0] = hundreds + CHAR_0_OFFSET;
    buf[1] = tens + CHAR_0_OFFSET;
    buf[2] = ones + CHAR_0_OFFSET;
}
