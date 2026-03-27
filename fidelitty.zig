//! A library for high performance rendering in the terminal using unicode characters and escape sequences.

// Imports
const unicode_ = @import("src/unicode_image.zig");
const terminal_ = @import("src/terminal_util.zig");
const compute_ = @import("src/compute.zig");
const dataset_config_ = @import("dataset_config");


// ================== ZIG API ====================

// =============== Core (headless) ================

/// Build-time configuration containing important metadata constants for the glyph dataset
pub const dataset_config = dataset_config_;

/// Struct storing data needed to construct one unicode pixel in a UnicodeImage
pub const UnicodePixelData = unicode_.UnicodePixelData;

/// Vulkan-based context for managing render pipelines, intended to be used as a singleton.
pub const ComputeContext = compute_.Context;

/// Non-owning handle to a render pipeline managed by the compute context, allowing input writing and output reading.
pub const PipelineHandle = compute_.PipelineHandle;

/// Pixel format for input surfaces
pub const PixelFormat = compute_.PixelFormat;

// In the future, I will add support for attaching the context to an existing Vulkan instance,
// allowing this library to be used a postprocessing step with data passed directly through the gpu.

// =============== Terminal frontend ================
// NOTE: The terminal frontend is experimental and has known bugs.

/// Utility functions for querying and manipulating the terminal
pub const terminal = terminal_;

/// Struct storing data for a ready-to-print image, and exposing methods for init / deinit, resizing, and read / write operations
pub const UnicodeImage = unicode_.UnicodeImage;


// =============== DEFINITIONS FOR C API ===============

// TODO: add double-buffering support - unclear how this should work just yet

const c_allocator = @import("std").heap.c_allocator;

// =============== Core (headless) ================

// CONTEXT MANAGEMENT

export fn ftty_context_create(max_pipelines: u8) callconv(.c) ?*ComputeContext {
    const ctx = c_allocator.create(ComputeContext) catch return null;
    ctx.* = ComputeContext.init(c_allocator, max_pipelines) catch {
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

export fn ftty_context_create_render_pipeline(ctx: *ComputeContext, w: u16, h: u16) callconv(.c) ?*PipelineHandle {
    const pipeline = c_allocator.create(PipelineHandle) catch return null;
    pipeline.* = ctx.createRenderPipeline(w, h) catch {
        c_allocator.destroy(pipeline);
        return null;
    };
    return pipeline;
}

export fn ftty_context_create_render_pipeline_ex(
    ctx: *ComputeContext,
    w: u16, h: u16,
    pixel_format: u8,
    src_cell_w: u8,
    src_cell_h: u8,
) callconv(.c) ?*PipelineHandle {
    const format: PixelFormat = @enumFromInt(pixel_format);
    const pipeline = c_allocator.create(PipelineHandle) catch return null;
    pipeline.* = ctx.createRenderPipelineEx(w, h, format, src_cell_w, src_cell_h) catch {
        c_allocator.destroy(pipeline);
        return null;
    };
    return pipeline;
}

export fn ftty_context_destroy_render_pipeline(ctx: *ComputeContext, pipeline: *PipelineHandle) callconv(.c) void {
    ctx.destroyRenderPipelines(pipeline[0..1]);
    c_allocator.destroy(pipeline);
}

export fn ftty_context_resize_render_pipeline(ctx: *ComputeContext, pipeline: *PipelineHandle, w: u16, h: u16) callconv(.c) i32 {
    ctx.resizeRenderPipeline(pipeline, w, h) catch {
        return -1;
    };
    return 0;
}

export fn ftty_context_execute_render_pipeline_all(ctx: *ComputeContext, pipeline: *PipelineHandle) callconv(.c) i32 {
    ctx.executeRenderPipelineAll(pipeline.*) catch {
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

export fn ftty_pipeline_get_dims(pipeline: *PipelineHandle, w: *u16, h: *u16) callconv(.c) void {
    w.* = pipeline.out_im_w;
    h.* = pipeline.out_im_h;
}

export fn ftty_pipeline_get_input_surface(pipeline: *PipelineHandle) callconv(.c) *u8 {
    return @ptrCast(pipeline.input_surface);
}

export fn ftty_pipeline_get_output_surface(pipeline: *PipelineHandle) callconv(.c) [*]UnicodePixelData {
    return @ptrCast(pipeline.output_surface);
}

// DATASET CONFIG

export fn ftty_get_patch_width() callconv(.c) u8 {
    return dataset_config.cell_virtual_w;
}

export fn ftty_get_patch_height() callconv(.c) u8 {
    return dataset_config.cell_virtual_h;
}
