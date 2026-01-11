const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const fs = std.fs;

const c = @cImport({
    @cInclude("stb_truetype.h");
});

pub fn getGlyphPixmapSet(codepoints: []u16, comptime w: u8, comptime h: u8,
                         generator: *const PixmapGenerator, allocator: mem.Allocator) ![]GlyphPixmap(w, h) {
    const pixmap_set: []GlyphPixmap(w, h) = try allocator.alloc(GlyphPixmap(w, h), codepoints.len);
    for (codepoints, 0..) |codepoint, i| {
        pixmap_set[i].generate(codepoint, generator);
    }
    return pixmap_set;
}

pub fn getCellAspect() ?f32 {
    var wsz: posix.winsize = undefined;
    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (rc != 0) return null;
    
    // ws_xpixel/ws_ypixel are often 0 on older terminals
    if (wsz.xpixel == 0 or wsz.ypixel == 0 or wsz.col == 0 or wsz.row == 0) {
        return null;
    }
    
    const cell_w = @as(f32, @floatFromInt(wsz.xpixel)) / @as(f32, @floatFromInt(wsz.col));
    const cell_h = @as(f32, @floatFromInt(wsz.ypixel)) / @as(f32, @floatFromInt(wsz.row));
    
    return cell_h / cell_w;
}

pub const DEFAULT_CELL_ASPECT: f32 = 2.0;
pub fn getCellAspectOrDefault() f32 {
    return getCellAspect() orelse DEFAULT_CELL_ASPECT;
}

pub fn GlyphPixmap(comptime w: u16, comptime h: u16) type {
    return struct {
        pixmap_pos: [w * h]u8,
        pixmap_neg: [w * h]u8,

        pub fn generate(self: *@This(), codepoint: u16, generator: *const PixmapGenerator) void {
            self.pixmap_pos = .{0} ** (w * h);
            generator.generateScaled(codepoint, w, h, &self.pixmap_pos);
            for (self.pixmap_pos, 0..) |pix, i| {
                self.pixmap_neg[i] = @as(u8, 0xff) - pix;
            }
        }

        pub fn print(self: @This()) void {
            for (0..h) |y| {
                for (0..w) |x| {
                    const val = self.pixmap_pos[y * w + x];
                    if (val > 0) {
                        std.debug.print("\x1b[38;2;{};{};{}m\u{2588}", .{val, val, val});
                    } else {
                        std.debug.print(".", .{});
                    }
                }
                std.debug.print("\n", .{});
            }
        }
    };
}

pub const PixmapGenerator = struct {
    font: c.stbtt_fontinfo,
    font_data: []u8,
    cell_aspect: f32,
    
    const SUPERSAMPLE: u16 = 32;
    const MAX_FONT_FILE_SIZE = 10000000;

    pub fn init(allocator: mem.Allocator, font_path: []const u8) !PixmapGenerator {
        return initWithAspect(allocator, font_path, getCellAspectOrDefault());
    }

    pub fn initWithAspect(allocator: mem.Allocator, font_path: []const u8, aspect: f32) !PixmapGenerator {
        const font_dir = try fs.openDirAbsolute("/usr/share/fonts", .{});
        const font_data = try font_dir.readFileAlloc(allocator, font_path, MAX_FONT_FILE_SIZE);
        var font: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(&font, font_data.ptr, 0) == 0) {
            return error.InvalidFontData;
        }
        return .{ .font = font, .font_data = font_data, .cell_aspect = aspect };
    }

    pub fn deinit(self: PixmapGenerator, allocator: mem.Allocator) void {
        allocator.free(self.font_data);
    }

    pub fn generateScaled(self: PixmapGenerator, codepoint: u16, comptime w: u16, comptime h: u16, pixmap_buf: *[w * h]u8) void {
        const virtual_w: u16 = w * SUPERSAMPLE;
        const virtual_h: u16 = @intFromFloat(@as(f32, @floatFromInt(w)) * self.cell_aspect * @as(f32, SUPERSAMPLE));

        // allocator for temp buf
        var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
        defer _=debug_allocator.deinit();
        const temp_buf: []u8 = debug_allocator.allocator().alloc(u8, virtual_w * virtual_h) catch {
            std.debug.print("Alloc failed", .{});
            return;
        };
        for (0..virtual_w*virtual_h) |n| {
            temp_buf[n] = 0;
        }
        
        defer debug_allocator.allocator().free(temp_buf);

        self.renderToBuffer(codepoint, virtual_w, virtual_h, temp_buf);

        const region_w = virtual_w / w;
        const region_h = virtual_h / h;

        for (0..h) |out_y| {
            for (0..w) |out_x| {
                var sum: u32 = 0;
                const start_x = out_x * region_w;
                const start_y = out_y * region_h;
                for (0..region_h) |dy| {
                    for (0..region_w) |dx| {
                        sum += temp_buf[(start_y + dy) * virtual_w + (start_x + dx)];
                    }
                }
                pixmap_buf[out_y * w + out_x] = @intCast(sum / (region_w * region_h));
            }
        }
    }

    fn renderToBuffer(self: PixmapGenerator, codepoint: u16, buf_w: u16, buf_h: u16, buf: []u8) void {
        const glyph_idx = c.stbtt_FindGlyphIndex(&self.font, codepoint);
        if (glyph_idx == 0) return;

        var ascent: c_int = undefined;
        var descent: c_int = undefined;
        var line_gap: c_int = undefined;
        c.stbtt_GetFontVMetrics(&self.font, &ascent, &descent, &line_gap);

        var advance_width: c_int = undefined;
        var left_bearing: c_int = undefined;
        c.stbtt_GetGlyphHMetrics(&self.font, glyph_idx, &advance_width, &left_bearing);

        const font_height = ascent - descent;
        const scale_y = @as(f32, @floatFromInt(buf_h)) / @as(f32, @floatFromInt(font_height));
        const scaled_advance = @as(f32, @floatFromInt(advance_width)) * scale_y;
        const scale_x = if (scaled_advance > @as(f32, @floatFromInt(buf_w)))
            @as(f32, @floatFromInt(buf_w)) / @as(f32, @floatFromInt(advance_width))
        else
            scale_y;

        var x0: c_int = undefined;
        var y0: c_int = undefined;
        var x1: c_int = undefined;
        var y1: c_int = undefined;
        c.stbtt_GetGlyphBitmapBox(&self.font, glyph_idx, scale_x, scale_y, &x0, &y0, &x1, &y1);

        const glyph_w = x1 - x0;
        const glyph_h = y1 - y0;
        if (glyph_w <= 0 or glyph_h <= 0) return;

        const baseline: i32 = @intFromFloat(@as(f32, @floatFromInt(ascent)) * scale_y);
        const total_advance: i32 = @intFromFloat(@as(f32, @floatFromInt(advance_width)) * scale_x);
        const center_offset_x = @divFloor(@as(i32, buf_w) - total_advance, 2);
        
        const draw_x: i32 = @max(0, center_offset_x + x0);
        const draw_y: i32 = @max(0, baseline + y0);

        const clamped_w: c_int = @min(glyph_w, @as(c_int, buf_w) - draw_x);
        const clamped_h: c_int = @min(glyph_h, @as(c_int, buf_h) - draw_y);
        if (clamped_w <= 0 or clamped_h <= 0) return;

        const offset: usize = @intCast(draw_y * buf_w + draw_x);
        c.stbtt_MakeGlyphBitmap(&self.font, buf[offset..].ptr, clamped_w, clamped_h, buf_w, scale_x, scale_y, glyph_idx);
    }
};

