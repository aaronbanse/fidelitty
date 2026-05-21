//! C ABI definitions for fidelitty. Root source file for shared-library builds;
//! see lib.zig for the Zig API.

// TODO: add double-buffering support - unclear how this should work just yet

const std = @import("std");

const ftty = @import("fidelitty");
const UnicodePixelData = ftty.UnicodePixelData;
const ComputeContext = ftty.ComputeContext;
const PipelineHandle = ftty.PipelineHandle;
const PixelFormat = ftty.PixelFormat;
const initFont = ftty.initFont;

const c_allocator = std.heap.c_allocator;
const Threaded = std.Io.Threaded.init(c_allocator, .{});
const c_io = Threaded.io();

// FONT GENERATION

// TODO: figure out how to get environ map without main's Init.
// export fn ftty_init_font(user_font_path: [*]const u8) callconv(.c) i32 {
//     ftty.initFont(c_io, c_allocator, user_font_path) catch {
//         return -1;
//     };
//     return 0;
// }

// CONTEXT MANAGEMENT

export fn ftty_context_create(max_pipelines: u8) callconv(.c) ?*ComputeContext {
    const ctx = c_allocator.create(ComputeContext) catch return null;
    ctx.init(c_allocator, max_pipelines) catch {
        c_allocator.destroy(ctx);
        return null;
    };
    return ctx;
}

export fn ftty_context_destroy(ctx: *ComputeContext) callconv(.c) void {
    ctx.deinit();
    c_allocator.destroy(ctx);
}

// PIPELINE MANAGEMENT

export fn ftty_context_create_render_pipeline(ctx: *ComputeContext, grid_w: u16, grid_h: u16) callconv(.c) ?*PipelineHandle {
    const pipeline = c_allocator.create(PipelineHandle) catch return null;
    pipeline.* = ctx.createRenderPipeline(grid_w, grid_h) catch {
        c_allocator.destroy(pipeline);
        return null;
    };
    return pipeline;
}

export fn ftty_context_create_render_pipeline_ex(
    ctx: *ComputeContext,
    grid_w: u16, grid_h: u16,
    pixel_format: u8,
    im_patch_w: u8,
    im_patch_h: u8,
) callconv(.c) ?*PipelineHandle {
    const format: PixelFormat = @enumFromInt(pixel_format);
    const pipeline = c_allocator.create(PipelineHandle) catch return null;
    pipeline.* = ctx.createRenderPipelineEx(grid_w, grid_h, format, im_patch_w, im_patch_h) catch {
        c_allocator.destroy(pipeline);
        return null;
    };
    return pipeline;
}

export fn ftty_context_destroy_render_pipeline(ctx: *ComputeContext, pipeline: *PipelineHandle) callconv(.c) void {
    ctx.destroyRenderPipelines(pipeline[0..1]);
    c_allocator.destroy(pipeline);
}

export fn ftty_context_resize_render_pipeline(ctx: *ComputeContext, pipeline: *PipelineHandle, grid_w: u16, grid_h: u16) callconv(.c) i32 {
    ctx.resizeRenderPipeline(pipeline, grid_w, grid_h) catch {
        return -1;
    };
    return 0;
}

export fn ftty_context_execute_render_pipeline(ctx: *ComputeContext, pipeline: *PipelineHandle) callconv(.c) i32 {
    ctx.executeRenderPipeline(pipeline.*) catch {
        return -1;
    };
    return 0;
}

export fn ftty_context_execute_render_pipeline_region(
    ctx: *ComputeContext, pipeline: *PipelineHandle,
    dispatch_x: u16, dispatch_y: u16,
    dispatch_w: u16, dispatch_h: u16,
) callconv(.c) i32 {
    ctx.executeRenderPipelineRegion(pipeline.*, dispatch_x, dispatch_y, dispatch_w, dispatch_h) catch {
        return -1;
    };
    return 0;
}

export fn ftty_context_wait_render_pipeline(ctx: *ComputeContext, pipeline: *PipelineHandle) callconv(.c) i32 {
    ctx.waitRenderPipeline(pipeline.*) catch {
        return -1;
    };
    return 0;
}

// PIPELINE I/O

export fn ftty_pipeline_get_dims(pipeline: *PipelineHandle, grid_w: *u16, grid_h: *u16) callconv(.c) void {
    grid_w.* = pipeline.grid_w;
    grid_h.* = pipeline.grid_h;
}

export fn ftty_pipeline_get_input_surface(pipeline: *PipelineHandle) callconv(.c) *u8 {
    return @ptrCast(pipeline.input_surface);
}

export fn ftty_pipeline_get_output_surface(pipeline: *PipelineHandle) callconv(.c) [*]UnicodePixelData {
    return @ptrCast(pipeline.output_surface);
}

// DATASET CONFIG

export fn ftty_get_cell_width() callconv(.c) u8 {
    return ftty.cell_w;
}

export fn ftty_get_cell_height() callconv(.c) u8 {
    return ftty.cell_h;
}
