const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const unicode = std.unicode;

// escape sequence to set the background color and foreground color for future printed characters,
// plus four null bytes of space reserved for a single unicode character.
// Unused space is "padded" with null bytes so as not to print extra characters to the terminal.
const PIXEL_STR_TEMPLATE: *const [42:0]u8 = "\x1b[48;2;000;000;000m\x1b[38;2;000;000;000m\x00\x00\x00\x00";

// auxiliary escape sequences for image positioning and syncing
const BEGIN_SYNC_SEQ = "\x1b[?2026h"; // begin synced output and reset cursor position
const END_SYNC_SEQ = "\x1b[?2026l"; // end synced output
const SET_CURSOR_SEQ_TEMPLATE = "\x1b[000;000H"; // fill in 0s to set cursor position. NOTE: 1-INDEXED!!

// Note- accepts 0-indexed, converts to 1-indexed. Max value is 998.
fn writeSetCursorSeq(x: u16, y: u16, buf: []u8) void {
    _=std.fmt.bufPrint(buf, SET_CURSOR_SEQ_TEMPLATE, .{}) catch {};
    _=std.fmt.printInt(buf[2..], y + 1, 10, .lower, .{.fill = 48, .width = 3});
    _=std.fmt.printInt(buf[6..], x + 1, 10, .lower, .{.fill = 48, .width = 3});
}

pub const UnicodePixelData = struct {
    br: u8,
    bg: u8,
    bb: u8,
    fr: u8,
    fg: u8,
    fb: u8,
    codepoint: u32,
};

pub const UnicodeImage = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    buf: []u8, // can be written directly
    
    pub fn init(self: *@This(), alloc: mem.Allocator, x: u16, y: u16, w: u16, h: u16) !void {
        self.buf = try alloc.alloc(u8, getSize(w, h));
        self.x = x;
        self.y = y;
        self.width = w;
        self.height = h;
        self.fillTemplate();
    }

    pub fn reinit(self: *@This(), alloc: mem.Allocator, x: u16, y: u16, w: u16, h: u16) !void {
        self.buf = try alloc.realloc(self.buf.len, getSize(w, h));
        self.x = x;
        self.y = y;
        self.width = w;
        self.height = h;
        self.fillTemplate();
    }

    pub fn deinit(self: *@This(), alloc: mem.Allocator) void {
        self.x = 0;
        self.y = 0;
        self.width = 0;
        self.height = 0;
        alloc.free(self.buf);
    }

    pub fn writePixel(self: @This(), data: UnicodePixelData, x: u16, y: u16) void {
        const row_start_idx = BEGIN_SYNC_SEQ.len + y * getRowSize(self.width);
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

    // convenience function for when you just want to write a pixel as a colored solid block
    pub fn writePixelColor(self: @This(), r: u8, g: u8, b: u8, x: u16, y: u16) void {
        self.writePixel(.{
            .br = 0,
            .bg = 0,
            .bb = 0,
            .fr = r,
            .fg = g,
            .fb = b,
            .codepoint = 0x2588, // full block
        }, @intCast(x), @intCast(y));
    }

    /// Fills a template for the image with it's size and position fixed.
    /// This consists of:
    /// 1. "begin sync" esc seq, telling terminal to print all out at once.
    /// 2. For each row, a "set cursor pos" esc seq and a set of escape sequence templates (colors/codepoint not set) for each colored unicode char.
    /// 3. "end sync" esc seq, signalling end of synced output.
    fn fillTemplate(self: *@This()) void {
        // for (0..self.buf.len) |n| {
        //     self.buf[n] = '-';
        // }
        _=fmt.bufPrint(self.buf, BEGIN_SYNC_SEQ, .{}) catch {};

        for (0..self.height) |y_| {
            const y: u16 = @intCast(y_);
            const row_start_idx = BEGIN_SYNC_SEQ.len + y * getRowSize(self.width);
            writeSetCursorSeq(self.x, self.y + y, self.buf[row_start_idx..]);
            const row_pixels_start_idx = row_start_idx + SET_CURSOR_SEQ_TEMPLATE.len;
            for (0..self.width) |x_| {
                const x: u16 = @intCast(x_);
                // print empty pixel string template
                const pix_index = row_pixels_start_idx + x * PIXEL_STR_TEMPLATE.len;
                _=fmt.bufPrint(self.buf[pix_index..], PIXEL_STR_TEMPLATE, .{}) catch {};
            }
        }

        _=fmt.bufPrint(self.buf[self.buf.len - END_SYNC_SEQ.len..], END_SYNC_SEQ, .{}) catch {};
    }

    fn getRowSize(w: u16) usize {
        return @as(usize, w) * PIXEL_STR_TEMPLATE.len + SET_CURSOR_SEQ_TEMPLATE.len;
    }

    fn getSize(w: u16, h: u16) usize {
        return @as(usize, BEGIN_SYNC_SEQ.len + END_SYNC_SEQ.len) + getRowSize(w) * h;
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

