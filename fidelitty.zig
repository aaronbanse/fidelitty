//! A library for high performance rendering in the terminal using unicode characters and escape sequences.
//! Allows for easy one-time renders or persistent graphics pipelines.

// Imports
const unicode_ = @import("src/unicode_image.zig");
const terminal_ = @import("src/terminal_util.zig");
const compute_ = @import("src/compute.zig");
const dataset_config_ = @import("dataset_config");
// You may notice the absence of glyph.zig in the imports.
// Glyph data is baked into compute.zig at compile time, so it can be configured using the build system.

// ================================================================================================
//
// NOTE: there is a current flaw in the API that needs to be addressed.
//
// I have not set up the ability for the compute shader to write to a UnicodeImage directly,
// so the conversion from an array of UnicodePixelData structs to a single UnicodeImage
// is handled on the cpu by the user, using the readPixelBuf method.
//
// As a consequence, the user is responsible for calling init / deinit / resize methods on the image,
// in concert with the associated Context methods for managing render pipelines.
//
// In the future, this will be changed so that a render pipeline outputs a UnicodeImage directly,
// and will tie the operations for managing resources together.
// This will allow us to remove UnicodePixelData from the API.
//
// ================================================================================================


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
    return dataset_config.patch_width;
}

export fn ftty_get_patch_height() callconv(.c) u8 {
    return dataset_config.patch_height;
}

// =============== Terminal frontend ================
// NOTE: The terminal frontend is experimental and has known bugs.

// UNICODE IMAGE MANAGEMENT

export fn ftty_unicode_image_create(w: u16, h: u16) ?*UnicodeImage {
    const img = c_allocator.create(UnicodeImage) catch return null;
    img.* = UnicodeImage.init(c_allocator, w, h) catch {
        c_allocator.destroy(img);
        return null;
    };
    return img;
}

export fn ftty_unicode_image_destroy(img: *UnicodeImage) void {
    img.deinit(c_allocator);
    c_allocator.destroy(img);
}

export fn ftty_unicode_image_resize(img: *UnicodeImage, w: u16, h: u16) i32 {
    img.resize(c_allocator, w, h) catch {
        return -1;
    };
    return 0;
}

export fn ftty_unicode_image_set_pos(img: *UnicodeImage, x: u16, y: u16) void {
    img.setPos(x, y);
}

export fn ftty_unicode_image_read_pixels(img: *UnicodeImage, pixels: [*]UnicodePixelData) void {
    img.readPixels(pixels);
}

export fn ftty_unicode_image_read_pixels_region(img: *UnicodeImage, pixels: [*]UnicodePixelData, x: u16, y: u16, w: u16, h: u16) void {
    img.readPixelsRegion(pixels, x, y, w, h);
}

export fn ftty_unicode_image_draw(img: *UnicodeImage) i32 {
    img.draw() catch {
        return -1;
    };
    return 0;
}

export fn ftty_unicode_image_draw_region(img: *UnicodeImage, x: u16, y: u16, w: u16, h: u16) i32 {
    img.drawRegion(x, y, w, h) catch {
        return -1;
    };
    return 0;
}

// TERMINAL UTILITIES

const TermDims = extern struct {
    cols: u16,
    rows: u16,
    cell_w: u16,
    cell_h: u16,
};

const CursorPos = extern struct {
    row: u16,
    col: u16,
};

export fn ftty_terminal_get_dims() callconv(.c) TermDims {
    const dims = terminal.getDims();
    return .{
        .cols = dims.cols,
        .rows = dims.rows,
        .cell_w = dims.cell_w,
        .cell_h = dims.cell_h,
    };
}

export fn ftty_terminal_reserve_vertical_space(rows: u16) callconv(.c) i32 {
    terminal_.reserveVerticalSpace(rows) catch {
        return -1;
    };
    return 0;
}

export fn ftty_terminal_get_cursor_pos(pos: *CursorPos) callconv(.c) i32 {
    const result = terminal.getCursorPos() catch {
        return -1;
    };
    pos.row = result.row;
    pos.col = result.col;
    return 0;
}
