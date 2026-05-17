//! A library for high performance rendering in the terminal using unicode characters and escape sequences.

const compute_ = @import("compute.zig");
const config_ = @import("config");
const font_ = @import("font.zig");

/// Build-time configuration containing important metadata constants for the glyph dataset
pub const config = config_;

/// Initialize the fidelitty font used for rendering. Derives metrics from
/// the user's specified default font so that glyphs fill the terminal cell.
pub const initFont = font_.initFont;

/// Struct storing the per-cell pixel data produced by a render pipeline
pub const UnicodePixelData = compute_.UnicodePixelData;

/// Vulkan-based context for managing render pipelines
pub const ComputeContext = compute_.Context;

/// Non-owning handle to a render pipeline managed by the compute context.
/// Write to input surface, dispatch, and read from output surface.
pub const PipelineHandle = compute_.PipelineHandle;

/// Pixel format for input surfaces
pub const PixelFormat = compute_.PixelFormat;

// In the future, I will add support for attaching the context to an existing Vulkan instance,
// allowing this library to be used a postprocessing step with data passed directly through the gpu.
