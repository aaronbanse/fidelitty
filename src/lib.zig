//! A library for high performance rendering in the terminal using unicode characters and escape sequences.

const std = @import("std");
const compute = @import("compute.zig");
const metrics = @import("font/metrics.zig");
const writer = @import("font/writer.zig");
const dataset = @import("dataset.zig");

pub const cell_w = dataset.cell_w;
pub const cell_h = dataset.cell_h;

/// Initialize the fidelitty font used for rendering. Derives metrics from
/// the user's specified default font so that glyphs fill the terminal cell.
/// Returns the path the font was installed to, whose memory must be managed by the caller.
pub fn initFont(
    io: std.Io,
    allocator: std.mem.Allocator,
    user_font_path: []const u8,
    user_home_dir: []const u8,
) ![]const u8 {
    const user_font_metrics = try metrics.getFontMetrics(io, user_font_path);
    return try writer.generateFromMetrics(
        io,
        allocator,
        user_font_metrics,
        user_home_dir,
    );
}

/// Struct storing the per-cell pixel data produced by a render pipeline
pub const UnicodePixelData = compute.UnicodePixelData;

/// Vulkan-based context for managing render pipelines
pub const ComputeContext = compute.Context;

/// Non-owning handle to a render pipeline managed by the compute context.
/// Write to input surface, dispatch, and read from output surface.
pub const PipelineHandle = compute.PipelineHandle;

/// Pixel format for input surfaces
pub const PixelFormat = compute.PixelFormat;

// In the future, I will add support for attaching the context to an existing Vulkan instance,
// allowing this library to be used a postprocessing step with data passed directly through the gpu.
