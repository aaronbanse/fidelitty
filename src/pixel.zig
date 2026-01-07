const fmt = @import("std").fmt;
const unicode = @import("std").unicode;

const TEMPLATE_STRING: *const [38:0]u8 = "\x1b[48;2;---;---;---m\x1b[38;2;---;---;---m";
pub const WORD_SIZE = TEMPLATE_STRING.len + 4; // fill last 4 with null bytes as padding for utf8

pub const UnicodePixel = struct {
    br: u8,
    bg: u8,
    bb: u8,
    fr: u8,
    fg: u8,
    fb: u8,
    codepoint_hex: u32,

    /// Fills buffer with string to produce a unicode character with background and foreground color specified.
    /// Assumes that buffers has been prefilled using getTemplateStringBuf
    pub fn print(self: UnicodePixel, buf: []u8) bool {
        if (buf.len < WORD_SIZE) return false;

        _=fmt.printInt(buf[7..], self.br, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[11..], self.bg, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[15..], self.bb, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[26..], self.fr, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[30..], self.fg, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[34..], self.fb, 10, fmt.Case.lower, .{.fill=48, .width=3});
        // encode utf8
        _=unicode.utf8Encode(@intCast(self.codepoint_hex), buf[38..]) catch {};

        return true;
    }
};

pub fn getTemplateStringBuf(buf: []u8) bool {
    if (buf.len < WORD_SIZE) return false;

    _=fmt.bufPrint(buf, TEMPLATE_STRING, .{}) catch {};
    buf[38] = 0;
    buf[39] = 0;
    buf[40] = 0;
    buf[41] = 0;

    return true;
}

