const std = @import("std");
const math = std.math;
const posix = std.posix;
const heap = std.heap;
const mem = std.mem;

const config = @import("config");

const glyph = @import("glyph.zig");
const uni_im = @import("unicode_image.zig");
const term = @import("terminal_util.zig");
const compute = @import("compute.zig");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub fn main() !void {
    // Config constants
    const patch_w = config.patch_width; // patch width
    const patch_h = config.patch_height; // patch height
    const charset_size = config.charset_size;
    const dataset_file = config.dataset_file;

    // Allocator
    var debug_allocator: heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // Load unicode glyph dataset from embedded data
    const dataset_raw = @embedFile(dataset_file);
    var dataset: glyph.UnicodeGlyphDataset(patch_w, patch_h, charset_size) = undefined;
    @memcpy(mem.asBytes(&dataset), dataset_raw);
    
    // load image from disk
    std.debug.print("Loading image... ", .{});
    var img_w: u32 = undefined;
    var img_h: u32 = undefined;
    var img_chan_n: u32 = undefined;
    const image_raw: [*]u8 = c.stbi_load(".img/img.jpg",
        @ptrCast(&img_w), @ptrCast(&img_h), @ptrCast(&img_chan_n), 3);
    defer c.stbi_image_free(image_raw);
    std.debug.print("Finished.\n", .{});

    // initialize compute context
    var compute_context: compute.Context = undefined;
    try compute_context.init(allocator, patch_w, patch_h, charset_size, &dataset, 8);
    defer compute_context.deinit();

    // create a render pipeline
    const term_dims = term.getDims();
    const out_image_h: u16 = term_dims.rows;
    const out_image_w: u16 = @intFromFloat(@as(f32, @floatFromInt(term_dims.rows * term_dims.cell_h)) // new_h
        * (@as(f32, @floatFromInt(img_w)) / @as(f32, @floatFromInt(img_h))) / @as(f32, @floatFromInt(term_dims.cell_w))); // old_w / old_h
    const pipeline_handle = try compute_context.createRenderPipeline(out_image_w, out_image_h);

    // get ratio of image size to expected input size (out image size * patch size)
    const exp_input_w: usize = @as(usize, out_image_w) * @as(usize, patch_w);
    const exp_input_h: usize = @as(usize, out_image_h) * @as(usize, patch_h);
    const x_rat: f32 = @as(f32, @floatFromInt(img_w)) / @as(f32, @floatFromInt(exp_input_w));
    const y_rat: f32 = @as(f32, @floatFromInt(img_h)) / @as(f32, @floatFromInt(exp_input_h));
    for (0..exp_input_h) |y| {
        for (0..exp_input_w) |x| {
            const img_x: usize = @intFromFloat(@as(f32, @floatFromInt(x)) * x_rat);
            const img_y: usize = @intFromFloat(@as(f32, @floatFromInt(y)) * y_rat);
            const src_idx = (img_y * img_w + img_x) * 3;
            const dst_idx = (y * exp_input_w + x) * 3;
            pipeline_handle.input_surface[dst_idx + 0] = image_raw[src_idx + 0];
            pipeline_handle.input_surface[dst_idx + 1] = image_raw[src_idx + 1];
            pipeline_handle.input_surface[dst_idx + 2] = image_raw[src_idx + 2];
        }
    }

    // Init output image to fill terminal
    var out_image: uni_im.UnicodeImage = undefined;
    try out_image.init(allocator, out_image_w, out_image_h);
    out_image.setPos(0,0);
    
    defer out_image.deinit(allocator);

    // run pipeline
    try compute_context.executeRenderPipelines(&.{pipeline_handle});

    // wait on completion
    try compute_context.waitRenderPipelines(&.{pipeline_handle});

    out_image.readPixelBuf(out_image_w, out_image_h, pipeline_handle.output_surface);
    try out_image.draw();
}

