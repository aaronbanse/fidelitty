const fmt = @import("std").fmt;

const TEMPLATE_STRING: *const [52:0]u8 = "\\x1b[48;2;---;---;---m\\x1b[38;2;---;---;---m\\U------";
pub const WORD_SIZE = TEMPLATE_STRING.len;

pub const UnicodePixel = struct {
    br: u8,
    bg: u8,
    bb: u8,
    fr: u8,
    fg: u8,
    fb: u8,
    char: [3]u8,

    /// Fills buffer with string to produce a unicode character with background and foreground color specified.
    /// Assumes that buffers has been prefilled with the following string:
    /// "\x1b[48;2;---;---;---m\x1b[38;2;---;---;---m\u----"
    pub fn print(self: UnicodePixel, buf: []u8) bool {
        if (buf.len < WORD_SIZE) return false;

        _=fmt.printInt(buf[10..], self.br, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[14..], self.bg, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[18..], self.bb, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[32..], self.fr, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[36..], self.fg, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[40..], self.fb, 10, fmt.Case.lower, .{.fill=48, .width=3});
        _=fmt.printInt(buf[46..], self.char[0], 16, fmt.Case.lower, .{.fill=48, .width=2});
        _=fmt.printInt(buf[48..], self.char[1], 16, fmt.Case.lower, .{.fill=48, .width=2});
        _=fmt.printInt(buf[50..], self.char[2], 16, fmt.Case.lower, .{.fill=48, .width=2});

        return true;
    }
};

pub fn getTemplateStringBuf(buf: []u8) bool {
    if (buf.len < WORD_SIZE) return false;

    for (TEMPLATE_STRING, 0..) |char, index| {
        buf[index] = char;
    }

    return true;
}

