const unicode_image = @import("unicode_image.zig");
const std = @import("std");

/// Data structure for storing a patch of an image, 
/// for use in determining the optimal unicode character to represent it
pub fn ImagePatch(comptime w: u8, comptime h: u8) type {
    return struct {
        r: @Vector(w*h, u8),
        g: @Vector(w*h, u8),
        b: @Vector(w*h, u8),

        /// Sample a patch from an image. For performance, uses strided sampling instead of bucketed.
        /// Assumes image is arranged row-major with r,g,b interleaved. So would look like r,g,b,r,g,b etc
        pub fn sample(self: *@This(), image: [*]const u8, im_w: u16, im_h: u16, uni_im_w: u16, uni_im_h: u16, patch_x: u16, patch_y: u16) void {
            // Calculate the pixel region this patch covers
            // Use integer math to handle non-divisible sizes
            const start_x: u16 = @intCast((@as(u32, patch_x) * im_w) / uni_im_w);
            const start_y: u16 = @intCast((@as(u32, patch_y) * im_h) / uni_im_h);
            const end_x: u16 = @intCast(((@as(u32, patch_x) + 1) * im_w) / uni_im_w);
            const end_y: u16 = @intCast(((@as(u32, patch_y) + 1) * im_h) / uni_im_h);
            
            const region_w = end_x - start_x;
            const region_h = end_y - start_y;
            
            // Sample w×h points from this region
            for (0..h) |row| {
                for (0..w) |col| {
                    // Map sample point to pixel coordinates within the region
                    const sample_x = start_x + (col * region_w) / w;
                    const sample_y = start_y + (row * region_h) / h;
                    
                    // Calculate index into the image buffer (row-major, RGB interleaved)
                    const pixel_idx = (sample_y * im_w + sample_x) * 3;
                    
                    const patch_idx = row * w + col;
                    self.r[patch_idx] = image[pixel_idx + 0];
                    self.g[patch_idx] = image[pixel_idx + 1];
                    self.b[patch_idx] = image[pixel_idx + 2];
                }
            }
        }
    };
}

