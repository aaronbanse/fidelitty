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
// In the future, this will be changed so that a render pipeline outputs a unicode image directly,
// and will tie the operations for managing resources together.
// This will allow us to remove UnicodePixelData from the API.
//
// ================================================================================================


// ================== PUBLIC API ====================

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

// In the future, I will add support for attaching the context to an existing Vulkan instance,
// allowing this library to be used a postprocessing step with data passed directly through the gpu.


