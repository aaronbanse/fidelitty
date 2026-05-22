const std = @import("std");
const math = std.math;
const posix = std.posix;
const heap = std.heap;
const mem = std.mem;

const ftty = @import("fidelitty");
const cell_w = ftty.cell_w;
const cell_h = ftty.cell_h;

const terminal = @import("terminal_util.zig");
const UnicodeImage = @import("unicode_image.zig").UnicodeImage;

const c = @cImport({
    @cInclude("stb_image.h");
});

const IMAGE_PATH = "examples/assets/merfolk-trickster.jpg";

pub fn main() !void {
    var debug_allocator: heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var Threaded = std.Io.Threaded.init(allocator, .{});
    defer Threaded.deinit();
    const io = Threaded.io();

    // load image from disk
    std.debug.print("Loading image... ", .{});
    var img_w: u32 = undefined;
    var img_h: u32 = undefined;
    var img_chan_n: u32 = undefined;
    const image_raw: [*]u8 = c.stbi_load(IMAGE_PATH,
        @ptrCast(&img_w), @ptrCast(&img_h), @ptrCast(&img_chan_n), 3);
    defer c.stbi_image_free(image_raw);
    std.debug.print("Finished.\n", .{});

    // initialize compute context
    var compute_context: ftty.ComputeContext = undefined;
    try compute_context.init(allocator, 8);
    defer compute_context.deinit();

    // create a render pipeline
    const term_dims = terminal.getDims();
    const grid_h: u16 = term_dims.grid_h;
    const grid_w: u16 = @intFromFloat(@as(f32, @floatFromInt(term_dims.grid_h * term_dims.term_cell_px_h)) // new_h
        * (@as(f32, @floatFromInt(img_w)) / @as(f32, @floatFromInt(img_h))) / @as(f32, @floatFromInt(term_dims.term_cell_px_w))); // old_w / old_h
    var pipeline_handle = try compute_context.createRenderPipeline(grid_w, grid_h);

    // get ratio of image size to expected input size (grid size * patch size)
    const exp_input_w: usize = @as(usize, grid_w) * @as(usize, cell_w);
    const exp_input_h: usize = @as(usize, grid_h) * @as(usize, cell_h);
    const x_rat: f32 = @as(f32, @floatFromInt(img_w)) / @as(f32, @floatFromInt(exp_input_w));
    const y_rat: f32 = @as(f32, @floatFromInt(img_h)) / @as(f32, @floatFromInt(exp_input_h));

    // sample from image to input surface
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
    var out_image: UnicodeImage = try .init(allocator, grid_w, grid_h);
    defer out_image.deinit(allocator);

    // reserve space on the screen for our image to avoid overwriting
    try terminal.reserveVerticalSpace(io, out_image.grid_h);
    const cursor_pos = try terminal.getCursorPos(io);
    out_image.setPos(cursor_pos.col, cursor_pos.row);

    const start = std.Io.Timestamp.now(io, .awake);
    try compute_context.executeRenderPipeline(pipeline_handle);
    try compute_context.waitRenderPipeline(pipeline_handle);
    out_image.readPixels(pipeline_handle.output_surface);
    try out_image.draw(io);
    const elapsed = start.untilNow(io, .awake);

    const elapsed_ms = @as(f64, @floatFromInt(elapsed.toNanoseconds())) / std.time.ns_per_ms;
    std.debug.print("\nRendered in {d:.2} ms\n", .{
        elapsed_ms,
    });
}
