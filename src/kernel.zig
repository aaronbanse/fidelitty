const std = @import("std");
const gpu = std.gpu;

const glyph = @import("glyph.zig");
const uni_im = @import("unicode_image.zig");

const dataset_config = @import("dataset_config");
const cell_w = dataset_config.cell_virtual_w;
const cell_h = dataset_config.cell_virtual_h;
const cell_size = cell_w * cell_h;

const gpu_buf_limits = @import("gpu_buf_limits");

const num_codepoints = glyph.UnicodeGlyphDataset(cell_w, cell_h).numCodepoints();

// TODO: switch to [patch_h]@Vector(patch_w, f32) for our patch / glyphs.
// zig backend won't auto-vectorize loops, and it won't unroll large vectors.
// So, we're stuck for now with NxM patches with N,M <= 4

// Static buffers, pushed once
const codepoints = @extern(*addrspace(.storage_buffer) extern struct {
    buf: [num_codepoints]u32,
}, .{
    .name = "codepoints",
    .decoration = .{ .descriptor = .{
        .binding = 0,
        .set = 0,
    } },
});
const masks = @extern(*addrspace(.storage_buffer) extern struct {
    buf: [num_codepoints]glyph.GlyphMask(cell_w, cell_h),
}, .{
    .name = "masks",
    .decoration = .{ .descriptor = .{
        .binding = 1,
        .set = 0,
    } },
});
const color_equations = @extern(*addrspace(.storage_buffer) extern struct {
    buf: [num_codepoints]glyph.ColorEqnCache,
}, .{
    .name = "color_equations",
    .decoration = .{ .descriptor = .{
        .binding = 2,
        .set = 0,
    } },
});

// I/O
const input_image = @extern(*addrspace(.storage_buffer) extern struct {
    buf: [gpu_buf_limits.image * cell_size * 4]u8,
}, .{
    .name = "input_image",
    .decoration = .{ .descriptor = .{
        .binding = 0,
        .set = 1,
    } },
});
const output_image = @extern(*addrspace(.storage_buffer) extern struct {
    buf: [gpu_buf_limits.image]uni_im.UnicodePixelData,
}, .{
    .name = "output_image",
    .decoration = .{ .descriptor = .{
        .binding = 1,
        .set = 1,
    } },
});

// Per-dispatch constants
const PushConstants = extern struct {
    num_codepoints: u32,
    out_im_w: u32,

    dispatch_x: u32,
    dispatch_y: u32,
    dispatch_w: u32,
    dispatch_h: u32,

    input_bpp: u32,
    swizzle: [3]u32,

    input_cell_w: u32,
    input_cell_h: u32,
    patch_w: u32,
    patch_h: u32,
};

extern var pc: PushConstants addrspace(.push_constant);

const CellColoring = struct {
    fore: f32,
    back: f32,
};

// Solver equation explained in-detail in README.md
fn solveChannel(
    mask_idx: usize,
    eqn: glyph.ColorEqnCache,
    patch_channel: [cell_size]f32,
) CellColoring {
    var mask_neg_dot: f32 = 0;
    var mask_pos_dot: f32 = 0;
    for (0..cell_size) |i| {
        mask_neg_dot += masks.buf[mask_idx].neg[i] * patch_channel[i];
        mask_pos_dot += masks.buf[mask_idx].pos[i] * patch_channel[i];
    }

    const back_numerator = mask_neg_dot * eqn.FF - mask_pos_dot * eqn.BF;
    const fore_numerator = mask_pos_dot * eqn.BB - mask_neg_dot * eqn.BF;

    return .{
        .back = std.math.clamp(back_numerator / eqn.det, 0.0, 255.0),
        .fore = std.math.clamp(fore_numerator / eqn.det, 0.0, 255.0),
    };
}

export fn main() callconv(.spirv_kernel) void {
    // gpu.executionMode(main, .{ .local_size = .{ .x = 64, .y = 1, .z = 1 } });

    const local_idx = gpu.global_invocation_id[0];

    const out_x = (local_idx % pc.dispatch_w) + pc.dispatch_x;
    const out_y = (local_idx / pc.dispatch_w) + pc.dispatch_y;
    const out_idx = out_y * pc.out_im_w + out_x;

    const in_x = out_x * pc.input_cell_w;
    const in_y = out_y * pc.input_cell_h;
    const in_im_w = pc.out_im_w * pc.input_cell_w;

    // Pull patch data from image
    var patch_rgb: [3][cell_size]f32 = undefined;
    for (0..pc.patch_h) |row| {
        const row_base = (in_y + row) * in_im_w + in_x;
        for (0..pc.patch_w) |col| {
            const src_col = col * pc.input_cell_w / pc.patch_w;
            const byte_off = (row_base + src_col) * pc.input_bpp;
            for (0..3) |chan| {
                patch_rgb[chan][row * cell_w + col] =
                    @floatFromInt(input_image.buf[byte_off + pc.swizzle[chan]]);
            }
        }
    }

    // Compute best unicode character and pixel
    var best_i: usize = 0;
    var best_diff: f32 = 1000000.0;
    var rgb_solved: [3]CellColoring = undefined;
    for (0..pc.num_codepoints) |i| {
        for (0..3) |chan| {
            rgb_solved[chan] = solveChannel(i, color_equations.buf[i], patch_rgb[chan]);
        }

        var diff: f32 = 0;
        for (0..3) |chan| {
            for (0..pc.patch_h) |row| {
                for (0..pc.patch_w) |col| {
                    const idx = row * cell_w + col;
                    const back_component = rgb_solved[chan].back * masks.buf[i].neg[idx];
                    const fore_component = rgb_solved[chan].fore * masks.buf[i].pos[idx];
                    const pixel_disparity = back_component + fore_component - patch_rgb[chan][idx];
                    diff += pixel_disparity * pixel_disparity;
                }
            }
        }

        best_i = if (diff < best_diff) i else best_i; // reduces to cmov, no branch
        best_diff = @min(diff, best_diff);
    }

    // Recomputing colors for best_i avoids branching in the main loop.
    // Conditionally copying a [3]CellColoring into a 'best rgb solved' is a full branch, versus
    // conditionally storing a usize into 'best_i', which reduces to a conditional move instruction.
    for (0..3) |chan| {
        rgb_solved[chan] = solveChannel(best_i, color_equations.buf[best_i], patch_rgb[chan]);
    }
    output_image.buf[out_idx] = .{
        .br = @intFromFloat(rgb_solved[0].back),
        .bg = @intFromFloat(rgb_solved[1].back),
        .bb = @intFromFloat(rgb_solved[2].back),
        .fr = @intFromFloat(rgb_solved[0].fore),
        .fg = @intFromFloat(rgb_solved[1].fore),
        .fb = @intFromFloat(rgb_solved[2].fore),
        ._pad = 0,
        .codepoint = codepoints.buf[best_i],
    };
}
