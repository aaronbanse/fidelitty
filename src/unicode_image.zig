const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const unicode = std.unicode;

const PIXEL_STR_TEMPLATE: *const [38:0]u8 = "\x1b[48;2;---;---;---m\x1b[38;2;---;---;---m";
pub const PIXEL_STR_SIZE: u6 = PIXEL_STR_TEMPLATE.len + 4; // fill last 4 with null bytes as padding for utf8

const PREFIX = "\x1b[?2026h\x1b[H"; // begin synced output and reset cursor position
const SUFFIX = "\x1b[?2026l"; // end synced output

pub const UnicodePixelData = struct {
    br: u8,
    bg: u8,
    bb: u8,
    fr: u8,
    fg: u8,
    fb: u8,
    codepoint_hex: u32,
};

pub const UnicodeImage = struct {
    width: u16,
    height: u16,
    buf: []u8, // can be written directly
    
    pub fn init(self: *@This(), alloc: mem.Allocator, w: u16, h: u16) !void {
        self.buf = try alloc.alloc(u8, getSize(w, h));
        self.width = w;
        self.height = h;
        self.fillTemplate();
    }

    pub fn reinit(self: *@This(), alloc: mem.Allocator, w: u16, h: u16) !void {
        self.buf = try alloc.realloc(self.buf.len, getSize(w, h));
        self.width = w;
        self.height = h;
        self.fillTemplate();
    }

    pub fn deinit(self: *@This(), alloc: mem.Allocator) void {
        self.width = 0;
        self.height = 0;
        alloc.free(self.buf);
    }

    pub fn writePixel(self: @This(), data: UnicodePixelData, x: u16, y: u16) !void {
        const pixel = self.buf[PREFIX.len + (@as(usize, y) * self.width + x) * PIXEL_STR_SIZE..];
        u8ToString(data.br, pixel[7..]);
        u8ToString(data.bg, pixel[11..]);
        u8ToString(data.bb, pixel[15..]);
        u8ToString(data.fr, pixel[26..]);
        u8ToString(data.fg, pixel[30..]);
        u8ToString(data.fb, pixel[34..]);
        // encode utf8
        _ = try unicode.utf8Encode(@intCast(data.codepoint_hex), pixel[38..]);
    }

    fn fillTemplate(self: *@This()) void {
        _=fmt.bufPrint(self.buf, PREFIX, .{}) catch {};
        var i: usize = PREFIX.len; // start at beginning of image data
        const len = getSize(self.width, self.height);
        while (i < len - SUFFIX.len) : (i += PIXEL_STR_SIZE) {
            const pixel_buf = self.buf[i..i+PIXEL_STR_SIZE];
            _=fmt.bufPrint(pixel_buf, PIXEL_STR_TEMPLATE, .{}) catch {};
            pixel_buf[38] = 0;
            pixel_buf[39] = 0;
            pixel_buf[40] = 0;
            pixel_buf[41] = 0;
        }
        _=fmt.bufPrint(self.buf[self.buf.len - SUFFIX.len..], SUFFIX, .{}) catch {};
    }

    fn getSize(w: u16, h: u16) usize {
        return @as(usize, PREFIX.len + SUFFIX.len) + @as(usize, w) * h * PIXEL_STR_SIZE;
    }
};

// Magic numbers for optimized division.
// Approximate 1/N as M/(2^k), so we can multiply by M and bit shift right by k.
const DIV_10_M: u16 = 205;
const DIV_10_SHIFT: u16 = 11;
const DIV_100_M: u16 = 41;
const DIV_100_SHIFT: u16 = 12;
// int to char conversion
const CHAR_0_OFFSET: u8 = 48;
// convert a u8 (0-255) to a 0-padded string of length 3
fn u8ToString(n: u8, buf: []u8) void {
    const hundreds: u8 = @intCast((@as(u16, n) * DIV_100_M) >> DIV_100_SHIFT);
    const mod_hundred: u8 = n - (hundreds * 100);
    const tens: u8 = @intCast((@as(u16, mod_hundred) * DIV_10_M) >> DIV_10_SHIFT);
    const ones: u8 = mod_hundred - (tens * 10);
    buf[0] = hundreds + CHAR_0_OFFSET;
    buf[1] = tens + CHAR_0_OFFSET;
    buf[2] = ones + CHAR_0_OFFSET;
}

