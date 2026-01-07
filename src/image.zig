const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const unicode = std.unicode;

const PIXEL_STR_TEMPLATE: *const [38:0]u8 = "\x1b[48;2;---;---;---m\x1b[38;2;---;---;---m";
pub const PIXEL_STR_SIZE: u6 = PIXEL_STR_TEMPLATE.len + 4; // fill last 4 with null bytes as padding for utf8

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
    data: []u8, // can be written directly
    
    pub fn init(self: *UnicodeImage, alloc: *const mem.Allocator, w: u16, h: u16) !void {
        self.data = try alloc.alloc(u8, @as(usize, w) * h * PIXEL_STR_SIZE);
        self.width = w;
        self.height = h;
        self.fillPixelTemplates();
    }

    pub fn reinit(self: *UnicodeImage, alloc: *const mem.Allocator, w: u16, h: u16) !void {
        self.data = try alloc.realloc(self.data.len, @as(usize, w) * h * PIXEL_STR_SIZE);
        self.width = w;
        self.height = h;
        self.fillPixelTemplates();
    }

    pub fn deinit(self: *UnicodeImage, alloc: *const mem.Allocator) !void {
        self.width = 0;
        self.height = 0;
        try alloc.free(self.data, self.data.len);
    }

    pub fn writePixel(self: UnicodeImage, data: UnicodePixelData, x: u16, y: u16) !void {
        const pixel = self.data[(@as(usize, y) * self.width + x) * PIXEL_STR_SIZE..];
        _=fmt.printInt(pixel[7..], data.br, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(pixel[11..], data.bg, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(pixel[15..], data.bb, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(pixel[26..], data.fr, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(pixel[30..], data.fg, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(pixel[34..], data.fb, 10, fmt.Case.lower, .{.fill=48, .width=3});
        // encode utf8
        _ = try unicode.utf8Encode(@intCast(data.codepoint_hex), pixel[38..]);
    }

    fn fillPixelTemplates(self: *UnicodeImage) void {
        var i: usize = 0;
        const len = @as(usize, self.width) * self.height * PIXEL_STR_SIZE;
        while (i < len) : (i += PIXEL_STR_SIZE) {
            const buf = self.data[i..i+PIXEL_STR_SIZE];
            _=fmt.bufPrint(buf, PIXEL_STR_TEMPLATE, .{}) catch {};
            buf[38] = 0;
            buf[39] = 0;
            buf[40] = 0;
            buf[41] = 0;
        }
    }
};

