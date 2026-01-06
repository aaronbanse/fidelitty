const heap = @import("std").heap;
const pixel = @import("unicode_pixel.zig");

pub const UnicodeImage = struct {
    width: u16,
    height: u16,
    data: []pixel.UnicodePixel,
    
    pub fn init(self: *UnicodeImage, alloc: *heap.Allocator, w: u16, h: u16) !void {
        self.data = try alloc.alloc(pixel.UnicodePixel, w * h);
        self.width = w;
        self.height = h;
    }

    pub fn reinit(self: *UnicodeImage, alloc: *heap.Allocator, w: u16, h: u16) !void {
        self.data = try alloc.realloc(self.data.len, w * h);
        self.width = w;
        self.height = h;
    }

    pub fn deinit(self: *UnicodeImage, alloc: *heap.Allocator) !void {
        self.width = 0;
        self.height = 0;
        try alloc.free(self.data, self.data.len);
    }

    pub fn getPixel(self: UnicodeImage, x: u16, y: u16) *pixel.UnicodePixel {
        return &self.data[y * self.width + x];
    }
};

