const std = @import("std");
const mem = std.mem;
const fs = std.fs;

const c = @cImport({
    @cInclude("stb_truetype.h");
});

/// struct storing the positive and negative space pixmaps for a glyph
pub fn GlyphPixmap(comptime w: u16, comptime h: u16) type {
    return struct {
        pixmap_pos: [w * h]u8,
        pixmap_neg: [w * h]u8,
        w: u16,
        h: u16,

        pub fn generate(codepoint: u16, generator: *const PixmapGenerator) GlyphPixmap(w,h) {
            var pixmap: GlyphPixmap(w,h) = .{
                .pixmap_pos = .{0} ** (w * h),
                .pixmap_neg = .{0} ** (w * h),
                .w = w,
                .h = h,
            };
            // get pos space pixmap from stb_truetype
            generator.generate(codepoint, w, h, &pixmap.pos);
            // calculate negative space pixmap
            for (pixmap.pixmap_pos, 0..) |pix, i| {
                pixmap.pixmap_neg[i] = @as(u8, 0xff) - pix;
            }
            return pixmap;
        }

        pub fn print(self: @This()) void {
            for (0..h) |y| {
                for (0..w) |x| {
                    if (self.buf[y * w + x] > 0) {
                        std.debug.print("\u{2588}", .{});
                    } else {
                        std.debug.print(" ", .{});
                    }
                }
                std.debug.print("\n", .{});
            }
        }
    };
}

pub const PixmapGenerator = struct {
    font: c.stbtt_fontinfo,
    font_data: []u8, // font also contains this data, but we can free
    
    const MAX_FONT_FILE_SIZE = 10000000; // 10 mb
    pub fn init(allocator: mem.Allocator, font_path: []const u8) !PixmapGenerator {
        // get font data
        const font_dir: fs.Dir = try fs.openDirAbsolute("/usr/share/fonts", .{});
        const font_data = try font_dir.readFileAlloc(allocator, 
            font_path, MAX_FONT_FILE_SIZE);

        // init font
        var font: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(&font, font_data.ptr, 0) == 0) { // returns 0 on failure
            return error.InvalidFontData;
        }

        return .{
            .font = font,
            .font_data = font_data,
        };
    }

    pub fn deinit(self: PixmapGenerator, allocator: mem.Allocator) void {
        allocator.free(self.font_data);
    }

    pub fn bufSize(self: PixmapGenerator) usize {
        return self.width * self.height;
    }

    pub fn generate(self: PixmapGenerator, codepoint: u16, comptime w: u16, comptime h: u16, pixmap_buf: []u8) void {
        const glyph = c.stbtt_FindGlyphIndex(&self.font, codepoint);
        const scale = c.stbtt_ScaleForPixelHeight(&self.font, @floatFromInt(h));

        var ascent: c_int = undefined;
        var descent: c_int = undefined;
        var line_gap: c_int = undefined;
        c.stbtt_GetFontVMetrics(&self.font, &ascent, &descent, &line_gap);

        var x0: c_int = undefined;
        var y0: c_int = undefined;
        var x1: c_int = undefined;
        var y1: c_int = undefined;
        c.stbtt_GetGlyphBitmapBox(&self.font, glyph, scale, scale, &x0, &y0, &x1, &y1);

        const glyph_w = x1 - x0;
        const glyph_h = y1 - y0;

        const baseline: i32 = @intFromFloat(@as(f32, @floatFromInt(ascent)) * scale);

        const draw_x: i32 = @max(0, x0);
        const draw_y: i32 = @max(0, baseline + y0);

        const clamped_w: c_int = @min(glyph_w, @as(c_int, w) - draw_x);
        const clamped_h: c_int = @min(glyph_h, @as(c_int, h) - draw_y);
    
        if (clamped_w <= 0 or clamped_h <= 0) return;

        const offset: usize = @intCast(draw_y * w + draw_x);
        c.stbtt_MakeGlyphBitmap(&self.font, pixmap_buf[offset..].ptr, clamped_w, clamped_h, w, scale, scale, glyph);
    }
};

