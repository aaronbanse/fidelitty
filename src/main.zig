const std = @import("std");
const math = std.math;
const posix = std.posix;
const heap = std.heap;

const glyph = @import("glyph.zig");
const uni_im = @import("unicode_image.zig");
const term = @import("terminal_util.zig");
const compute = @import("compute.zig");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub fn main() !void {
    var debug_allocator: heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // setup dimensions
    const term_dims = term.getDims();
    const w = 4; // patch width
    const h = 4; // patch height

    // get codepoints
    const u8_vals: u16 = math.maxInt(u8) + 1; // num vals u8 can take
    var codepoints: [u8_vals*2]u32 = undefined;
    for (0..u8_vals) |n| {
        codepoints[n] = 0x2800 + @as(u16, @intCast(n));
        if (n == 0x91 or n == 0x92 or n == 0x93) {
            codepoints[n+u8_vals] = 0x2500;
        } else {
            codepoints[n+u8_vals] = 0x2500 + @as(u16, @intCast(n));
        }
    }

    // precompute glyph set cache
    var glyph_set_cache: glyph.GlyphSetCache(w,h) = undefined;
    try glyph_set_cache.init(&codepoints, allocator);
    defer glyph_set_cache.deinit(allocator);

    // load image from disk
    var img_w: u32 = undefined;
    var img_h: u32 = undefined;
    var img_chan_n: u32 = undefined;
    const image_raw: [*]u8 = c.stbi_load("/home/acbanse/Projects/fidelitty/.img/IMG_3706.JPEG",
        @ptrCast(&img_w), @ptrCast(&img_h), @ptrCast(&img_chan_n), 3);
    defer c.stbi_image_free(image_raw);

    // initialize compute context
    var compute_context: compute.Context = undefined;
    try compute_context.init(allocator, w, h, glyph_set_cache, 8);
    defer compute_context.deinit();

    // create a render pipeline
    const pipeline_handle = try compute_context.createRenderPipeline(32, 32);

    // TEMP: will delete----------
    const image_flipped: []u8 = try allocator.alloc(u8, img_w * img_h * 3);
    defer allocator.free(image_flipped);
    for (0..img_h) |y| {
        for (0..img_w) |x| {
            for (0..3) |chan| {
                const idx = img_w * y + x;
                const idx_flipped = (img_w * img_h) - idx - 1;
                image_flipped[idx*3 + chan] = image_raw[idx_flipped*3 + chan];
            }
        }
    }
    // END TEMP-------------------

    // TODO: read image into pipelin handle input surface

    // run pipeline
    try compute_context.executeRenderPipelines(&.{pipeline_handle});

    // wait on completion
    try compute_context.waitRenderPipelines(&.{pipeline_handle});

    // Init output image to fill terminal
    var out_image: uni_im.UnicodeImage = undefined;
    const out_image_h: u16 = term_dims.rows;
    const out_image_w: u16 = @intFromFloat(@as(f32, @floatFromInt(term_dims.rows * term_dims.cell_h)) // new_h
        * (@as(f32, @floatFromInt(img_w)) / @as(f32, @floatFromInt(img_h))) / @as(f32, @floatFromInt(term_dims.cell_w))); // old_w / old_h
    try out_image.init(allocator, 0, 0, out_image_w, out_image_h);
    defer out_image.deinit(allocator);

    // write pixels to image
    for (0..out_image_h) |y| {
        for (0..out_image_w) |x| {
            out_image.writePixel(pipeline_handle.output_surface[y * out_image_w + x], @intCast(x), @intCast(y));
        }
    }

    // print image
    _ = try posix.write(1, out_image.buf);
}

