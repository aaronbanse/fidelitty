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

/// Build-time configuration containing important metadata constants for the glyph dataset
pub const dataset_config = dataset_config_;

/// Utility functions for querying and manipulating the terminal
pub const terminal = terminal_;

/// Struct storing data for a ready-to-print image, and exposing methods for init / deinit, resizing, and read / write operations
pub const UnicodeImage = unicode_.UnicodeImage;

/// Struct storing data needed to construct one unicode pixel in a UnicodeImage
pub const UnicodePixelData = unicode_.UnicodePixelData;

/// Vulkan-based context for managing render pipelines, intended to be used as a singleton.
pub const ComputeContext = compute_.Context;

/// Non-owning handle to a render pipeline managed by the compute context, allowing input writing and output reading.
pub const PipelineHandle = compute_.PipelineHandle;

// In the future, I will add support for attaching the context to an existing Vulkan instance,
// allowing this library to be used a postprocessing step with data passed directly through the gpu.

// =============== DEFINITIONS FOR C API ===============

// TODO: add double-buffering support - unclear how this should work just yet

const c_allocator = @import("std").heap.c_allocator;

export fn ftty_context_create(max_pipelines: u8) callconv(.C) ?*ComputeContext {
    const ctx = c_allocator.create(ComputeContext) catch return null;
    ctx.* = ComputeContext.init(c_allocator, max_pipelines) catch {
        c_allocator.destroy(ctx);
        return null;
    };
    return ctx;
}

export fn ftty_context_destroy(ctx: *ComputeContext) callconv(.C) void {
    ctx.deinit();
    c_allocator.destroy(ctx);
}

export fn ftty_context_create_render_pipeline(ctx: *ComputeContext, w: u16, h: u16) callconv(.C) ?*PipelineHandle {
    const pipeline = c_allocator.create(PipelineHandle) catch return null;
    pipeline.* = ctx.createRenderPipeline(w, h) catch {
        c_allocator.destroy(pipeline);
        return null;
    };
    return pipeline;
}

export fn ftty_context_destroy_render_pipeline(ctx: *ComputeContext, pipeline: *PipelineHandle) callconv(.C) void {
    ctx.destroyRenderPipelines(pipeline[0..1]);
    c_allocator.destroy(pipeline);
}

export fn ftty_context_resize_render_pipeline(ctx: *ComputeContext, pipeline: *PipelineHandle, w: u16, h: u16) callconv(.C) i32 {
    ctx.resizeRenderPipeline(pipeline, w, h) catch {
        return -1;
    };
    return 0;
}

export fn ftty_context_execute_render_pipeline(ctx: *ComputeContext, pipeline: *PipelineHandle) callconv(.C) i32 {
    ctx.executeRenderPipelines(pipeline[0..1]) catch {
        return -1;
    };
    return 0;
}

export fn ftty_context_wait_render_pipeline(ctx: *ComputeContext, pipeline: *PipelineHandle) callconv(.C) i32 {
    ctx.waitRenderPipelines(pipeline[0..1]) catch {
        return -1;
    };
    return 0;
}

export fn ftty_pipeline_get_dims(pipeline: *PipelineHandle, w: *u16, h: *u16) callconv(.C) void {
    w.* = pipeline.out_im_w;
    h.* = pipeline.out_im_h;
}

export fn ftty_pipeline_get_input_surface(pipeline: *PipelineHandle) callconv(.C) *u8 {
    return pipeline.input_surface;
}

export fn ftty_pipeline_get_output_surface(pipeline: *PipelineHandle) callconv(.C) *UnicodePixelData {
    return pipeline.output_surface;
}
