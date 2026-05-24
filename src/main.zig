//! ftty CLI: installs the rendering font or renders images to the terminal.

const std = @import("std");
const ftty = @import("fidelitty");
const c = @import("view_c");

fn cmdInit(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    user_home_dir_path: []const u8,
) !void {
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const stderr = &stderr_writer.interface;

    if (args.len != 3) {
        try stderr.writeAll("usage: ftty init <path_to_user_font>\n");
        std.process.exit(1);
    }

    const user_font_path = args[2];
    const installed_path = try ftty.initFont(io, allocator, user_font_path, user_home_dir_path);
    defer allocator.free(installed_path);

    // A terminal caches its font set (and per-codepoint glyph lookups) at
    // startup, so it won't pick up the freshly installed glyph set until
    // fontconfig's cache is refreshed and the terminal is restarted.
    try stderr.print(
        "Font installed to {s}\n" ++
            "Run `fc-cache -f` then restart your terminal for the font to be discovered.\n",
        .{installed_path},
    );
    try stderr.flush();
}

fn cmdView(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
) !void {
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const stderr = &stderr_writer.interface;

    if (args.len != 3) {
        try stderr.writeAll("usage: ftty view <path_to_image>\n");
        std.process.exit(1);
    }
    const image_path = args[2];

    // Decode image into RGB bytes via stb_image.
    var img_w: u32 = undefined;
    var img_h: u32 = undefined;
    const image_raw: ?[*]u8 = c.stbi_load(
        image_path.ptr,
        @ptrCast(&img_w),
        @ptrCast(&img_h),
        null,
        3,
    );
    const image_bytes = image_raw orelse {
        try stderr.print("failed to load image: {s}\n", .{image_path});
        try stderr.flush();
        std.process.exit(1);
    };
    defer c.stbi_image_free(image_bytes);

    var compute_context: ftty.ComputeContext = undefined;
    try compute_context.init(allocator, 8);
    defer compute_context.deinit();

    // Pick the largest cell grid that preserves the image's aspect ratio and
    // fits within the terminal's grid bounds.
    const term_dims = ftty.terminal.getDims();
    const img_w_f: f32 = @floatFromInt(img_w);
    const img_h_f: f32 = @floatFromInt(img_h);
    const cell_w_px: f32 = @floatFromInt(term_dims.term_cell_px_w);
    const cell_h_px: f32 = @floatFromInt(term_dims.term_cell_px_h);
    // grid_w/grid_h ratio that matches img_w/img_h once cells are stretched
    // to their non-square pixel footprint.
    const ratio: f32 = (img_w_f / img_h_f) * (cell_h_px / cell_w_px);
    const term_grid_w_f: f32 = @floatFromInt(term_dims.grid_w);
    const term_grid_h_f: f32 = @floatFromInt(term_dims.grid_h);
    const grid_w: u16, const grid_h: u16 = if (term_grid_h_f * ratio <= term_grid_w_f)
        .{ @intFromFloat(term_grid_h_f * ratio), term_dims.grid_h }
    else
        .{ term_dims.grid_w, @intFromFloat(term_grid_w_f / ratio) };
    var pipeline_handle = try compute_context.createRenderPipeline(grid_w, grid_h);

    // Nearest-neighbor sample the image into the pipeline's input surface.
    const exp_input_w: usize = @as(usize, grid_w) * @as(usize, ftty.cell_w);
    const exp_input_h: usize = @as(usize, grid_h) * @as(usize, ftty.cell_h);
    const x_rat: f32 = @as(f32, @floatFromInt(img_w)) / @as(f32, @floatFromInt(exp_input_w));
    const y_rat: f32 = @as(f32, @floatFromInt(img_h)) / @as(f32, @floatFromInt(exp_input_h));
    for (0..exp_input_h) |y| {
        for (0..exp_input_w) |x| {
            const img_x: usize = @intFromFloat(@as(f32, @floatFromInt(x)) * x_rat);
            const img_y: usize = @intFromFloat(@as(f32, @floatFromInt(y)) * y_rat);
            const src_idx = (img_y * img_w + img_x) * 3;
            const dst_idx = (y * exp_input_w + x) * 3;
            pipeline_handle.input_surface[dst_idx + 0] = image_bytes[src_idx + 0];
            pipeline_handle.input_surface[dst_idx + 1] = image_bytes[src_idx + 1];
            pipeline_handle.input_surface[dst_idx + 2] = image_bytes[src_idx + 2];
        }
    }

    var out_image: ftty.UnicodeImage = try .init(allocator, grid_w, grid_h);
    defer out_image.deinit(allocator);

    try ftty.terminal.reserveVerticalSpace(io, out_image.grid_h);
    const cursor_pos = try ftty.terminal.getCursorPos(io);
    out_image.setPos(cursor_pos.col, cursor_pos.row);

    try compute_context.executeRenderPipeline(pipeline_handle);
    try compute_context.waitRenderPipeline(pipeline_handle);
    out_image.readPixels(pipeline_handle.output_surface);
    try out_image.draw(io);

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "\n");
}

pub fn main(init: std.process.Init) !void {
    var arena_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();
    const io = init.io;
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const stderr = &stderr_writer.interface;
    
    const usage_str = "usage: ftty <init|view> <args...>\n";

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try stderr.writeAll(usage_str);
        std.process.exit(1);
    }
    if (std.mem.eql(u8, args[1], "init")) {
        const home_dir = init.environ_map.get("HOME") orelse {
            std.log.err("no home dir", .{});
            std.process.exit(1);
        };
        try cmdInit(io, arena, args, home_dir);
    } else if (std.mem.eql(u8, args[1], "view")) {
        try cmdView(io, arena, args);
    } else {
        try stderr.writeAll(usage_str);
        std.process.exit(1);
    }
}
