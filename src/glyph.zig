const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const heap = std.heap;
const math = std.math;
const debug = std.debug;
const Io = std.Io;

const term = @import("terminal_util.zig");

const c = @cImport({
    @cInclude("stb_truetype.h");
});

/// initializes, a set of glyph masks. Looped over to compute best glyph for a given patch.
pub fn getGlyphMaskSet(
    comptime w: u8,
    comptime h: u8,
    codepoints: []const u32,
    generator: *const GlyphMaskGenerator,
    masks: []GlyphMask(w, h)
) !void {
    for (codepoints, 0..) |codepoint, i| {
        try masks[i].generate(codepoint, generator);
    }
}

/// Data structure storing a vector mask of vals in [0,1] of the positive and negative space of a glyph.
pub fn GlyphMask(comptime w: u8, comptime h: u8) type {
    // extern to conform to C ABI since this data is pushed across CPU / GPU boundaries
    return extern struct {
        neg: [w*h]f32,
        pos: [w*h]f32,

        pub fn generate(self: *@This(), codepoint: u32, generator: *const GlyphMaskGenerator) !void {
            try generator.generateScaled(codepoint, w, h, &self.pos);
            self.neg = @as(@Vector(w*h, f32), @splat(1.0)) - self.pos;
        }
    };
}

pub const GlyphMaskGenerator = struct {
    font: c.stbtt_fontinfo,
    font_data: []u8,
    cell_aspect: f32,
    
    const SUPERSAMPLE: u16 = 32;
    const MAX_FONT_FILE_SIZE = 10000000;

    // initialize a glyph mask generator from a font
    pub fn init(allocator: mem.Allocator, font_path: []const u8) !GlyphMaskGenerator {
        const dims = term.getDims();
        return initWithAspect(allocator, font_path,
            @as(f32, @floatFromInt(dims.cell_h)) / @as(f32, @floatFromInt(dims.cell_w)));
    }
    
    // specify aspect ratio
    pub fn initWithAspect(allocator: mem.Allocator, font_path: []const u8, aspect: f32) !GlyphMaskGenerator {
        const font_dir = try fs.openDirAbsolute("/usr/share/fonts", .{});
        const font_data = try font_dir.readFileAlloc(allocator, font_path, MAX_FONT_FILE_SIZE);
        var font: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(&font, font_data.ptr, 0) == 0) {
            return error.InvalidFontData;
        }
        return .{ .font = font, .font_data = font_data, .cell_aspect = aspect };
    }

    pub fn deinit(self: GlyphMaskGenerator, allocator: mem.Allocator) void {
        allocator.free(self.font_data);
    }

    // Generate a glyph mask of arbitrary dimensions effectively stretched from how the glyph appears in a terminal cell.
    pub fn generateScaled(self: GlyphMaskGenerator, codepoint: u32, comptime w: u16, comptime h: u16, mask_buf: []f32) !void {
        // Set dims for high-res glyph mask to downsample from
        const virtual_w: u16 = w * SUPERSAMPLE;
        const virtual_h: u16 = @intFromFloat(@as(f32, @floatFromInt(w)) * self.cell_aspect * @as(f32, SUPERSAMPLE));

        // allocate temp buf for high-res render
        var debug_allocator: heap.DebugAllocator(.{}) = .init;
        defer _=debug_allocator.deinit();
        const temp_buf: []u8 = try debug_allocator.allocator().alloc(u8, virtual_w * virtual_h);

        for (0..virtual_w*virtual_h) |n| {
            temp_buf[n] = 0;
        }
        
        defer debug_allocator.allocator().free(temp_buf);

        // Render high-res to buffer
        self.renderToBuffer(codepoint, virtual_w, virtual_h, temp_buf);

        // Downsample and stretch aspect to target dimensions
        const region_w = virtual_w / w;
        const region_h = virtual_h / h;
        for (0..h) |out_y| {
            for (0..w) |out_x| {
                var sum: u32 = 0;
                const start_x = out_x * region_w;
                const start_y = out_y * region_h;
                for (0..region_h) |dy| {
                    for (0..region_w) |dx| {
                        sum += if (temp_buf[(start_y + dy) * virtual_w + (start_x + dx)] > 0) 255 else 0;
                    }
                }
                mask_buf[out_y * w + out_x] = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(region_w * region_h)) / 255;
            }
        }
    }

    // Render a unicode character to a buffer of a fixed size.
    fn renderToBuffer(self: GlyphMaskGenerator, codepoint: u32, buf_w: u16, buf_h: u16, buf: []u8) void {
        debug.assert(codepoint < math.maxInt(c_int));
        const glyph_idx = c.stbtt_FindGlyphIndex(&self.font, @intCast(codepoint));
        if (glyph_idx == 0) return;

        var ascent: c_int = undefined;
        var descent: c_int = undefined;
        var line_gap: c_int = undefined;
        c.stbtt_GetFontVMetrics(&self.font, &ascent, &descent, &line_gap);

        var advance_width: c_int = undefined;
        var left_bearing: c_int = undefined;
        c.stbtt_GetGlyphHMetrics(&self.font, glyph_idx, &advance_width, &left_bearing);

        const font_height = ascent - descent;

        const is_box_drawing = (codepoint >= 0x2500 and codepoint <= 0x259F);

        var scale_x: f32 = undefined;
        var scale_y: f32 = undefined;
        if (is_box_drawing) {
            scale_y = @as(f32, @floatFromInt(buf_h)) / @as(f32, @floatFromInt(font_height));
            scale_x = @as(f32, @floatFromInt(buf_w)) / @as(f32, @floatFromInt(advance_width));
        } else {
            // Normal glyphs: uniform scaling based on cell height
            scale_y = @as(f32, @floatFromInt(buf_h)) / @as(f32, @floatFromInt(font_height));
            scale_x = scale_y; // Keep aspect ratio
        }
        // const scale_y = @as(f32, @floatFromInt(buf_h)) / @as(f32, @floatFromInt(font_height));
        // const scaled_advance = @as(f32, @floatFromInt(advance_width)) * scale_y;
        // const scale_x = if (scaled_advance > @as(f32, @floatFromInt(buf_w)))
        //     @as(f32, @floatFromInt(buf_w)) / @as(f32, @floatFromInt(advance_width))
        // else
        //     scale_y;

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

/// Data structure for storing all data related to glyph masks, in it's simplest form for the compute kernel
pub fn UnicodeGlyphDataset(comptime w: u8, comptime h: u8, comptime n: u16) type {
    return struct {
        codepoints: [n]u32,
        masks: [n]GlyphMask(w, h),
        color_eqns: [n]ColorEqnParams,

        /// Takes and saves a set of codepoints, allocates and generates the masks and color equation params.
        /// Additionally allocates space to render the glyphs to, frees on completion.
        pub fn init(self: *@This(), codepoints: []const u32, allocator: mem.Allocator) !void {
            // copy pointer to codepoints
            @memcpy(&self.codepoints, codepoints);

            // create mask generator
            const glyph_mask_generator: GlyphMaskGenerator = try .init(allocator, "Adwaita/AdwaitaMono-Regular.ttf");
            defer glyph_mask_generator.deinit(allocator);

            // generate masks
            try getGlyphMaskSet(w, h, codepoints, &glyph_mask_generator, &self.masks);

            // precompute glyph color solvers
            for (0..codepoints.len) |i| {
                self.color_eqns[i] = ColorEqnParams.compute(w, h, self.masks[i]);
            }
        }
    };
}

/// Data structure for storing parameters of the color solver eqution that are only mask-dependent
pub const ColorEqnParams = extern struct {
// extern to conform to C ABI since this data is pushed across CPU / GPU boundaries
    BB: f32,  // B dot B
    FF: f32,  // F dot F
    BF: f32,  // B dot F  /  F dot B
    det: f32, // FF*BB - BF*BF

    pub fn compute(comptime w: u8, comptime h: u8, mask: GlyphMask(w,h)) ColorEqnParams {
        const dims = w * h;
        return .{
            .BB = dot(dims, &mask.neg, &mask.neg),
            .FF = dot(dims, &mask.pos, &mask.pos),
            .BF = dot(dims, &mask.neg, &mask.pos),
            .det = dot(dims, &mask.neg, &mask.neg) * dot(dims, &mask.pos, &mask.pos)
                 - dot(dims, &mask.neg, &mask.pos) * dot(dims, &mask.neg, &mask.pos)
        };
    }

    fn dot(dims: u8, a: []const f32, b: []const f32) f32 {
        debug.assert(@as(usize, dims) == a.len and a.len == b.len);
        var sum: f32 = 0;
        for (0..dims) |n| {
            sum += a[n] * b[n];
        }
        return sum;
    }
};

