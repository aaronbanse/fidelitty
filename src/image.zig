const mem = @import("std").mem;
const pix = @import("pixel.zig");

pub const UnicodeImage = struct {
    width: u16,
    height: u16,
    data: []u8,
    
    pub fn init(self: *UnicodeImage, alloc: *mem.Allocator, w: u16, h: u16) !void {
        self.data = try alloc.alloc(pix.WORD_SIZE, w * h);
        self.width = w;
        self.height = h;
        self.fillPixelTemplates();
    }

    pub fn reinit(self: *UnicodeImage, alloc: *mem.Allocator, w: u16, h: u16) !void {
        self.data = try alloc.realloc(self.data.len, w * h);
        self.width = w;
        self.height = h;
        self.fillPixelTemplates();
    }

    pub fn deinit(self: *UnicodeImage, alloc: *mem.Allocator) !void {
        self.width = 0;
        self.height = 0;
        try alloc.free(self.data, self.data.len);
    }

    pub fn getPixel(self: UnicodeImage, x: u16, y: u16) []u8 {
        return self.data[(y * self.width + x) * pix.WORD_SIZE .. (y * self.width + x + 1) * pix.WORD_SIZE];
    }

    fn fillPixelTemplates(self: *UnicodeImage) void {
        var i: u32 = 0;
        const len = self.width * self.height * pix.WORD_SIZE;
        while (i < len) : (i += pix.WORD_SIZE) {
            pix.getTemplateStringBuf(self.data[i..i+pix.WORD_SIZE]);
        }
    }
};

