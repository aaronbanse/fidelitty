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
    
    pub fn init(self: *UnicodeImage, alloc: *const mem.Allocator, w: u16, h: u16) !void {
        self.buf = try alloc.alloc(u8, getSize(w, h));
        self.width = w;
        self.height = h;
        self.fillTemplate();
    }

    pub fn reinit(self: *UnicodeImage, alloc: *const mem.Allocator, w: u16, h: u16) !void {
        self.buf = try alloc.realloc(self.buf.len, getSize(w, h));
        self.width = w;
        self.height = h;
        self.fillTemplate();
    }

    pub fn deinit(self: *UnicodeImage, alloc: *const mem.Allocator) void {
        self.width = 0;
        self.height = 0;
        alloc.free(self.buf);
    }

    pub fn writePixel(self: UnicodeImage, data: UnicodePixelData, x: u16, y: u16) !void {
        const pixel = self.buf[PREFIX.len + (@as(usize, y) * self.width + x) * PIXEL_STR_SIZE..];
        _=fmt.printInt(pixel[7..], data.br, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(pixel[11..], data.bg, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(pixel[15..], data.bb, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(pixel[26..], data.fr, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(pixel[30..], data.fg, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(pixel[34..], data.fb, 10, fmt.Case.lower, .{.fill=48, .width=3});
        // encode utf8
        _ = try unicode.utf8Encode(@intCast(data.codepoint_hex), pixel[38..]);
    }

    fn fillTemplate(self: *UnicodeImage) void {
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

