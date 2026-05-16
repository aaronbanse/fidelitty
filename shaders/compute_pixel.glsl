#version 450
#extension GL_EXT_shader_8bit_storage: require
#extension GL_EXT_shader_explicit_arithmetic_types_int8: require

layout(local_size_x = 64) in;

// Define a vector type for efficient operations on cells.
// Since vector ops max out at vec4, we create a custom type packed with vec4's plus a remainder vec4.
// Note that the remaining unused space in the last vec4 contains garbage values and affects
// the result of dot products and other reduction operations.

#if VEC4_REMAINDER == 0
    #define N_VEC4 VEC4_QUOTIENT
#else
    #define N_VEC4 (VEC4_QUOTIENT + 1)
#endif

struct CellVec {
    vec4[N_VEC4] vecs;
};

void setValue(inout CellVec v, uint x, uint y, float val) {
    const uint i = y * CELL_W + x;
    v.vecs[i / 4][i % 4] = val;
}

void zeroUnused(inout CellVec v) {
  #if VEC4_REMAINDER > 0
    for (uint i = VEC4_REMAINDER; i < 4; i++) {
        v.vecs[N_VEC4 - 1][i] = 0;
    }
  #endif
}

// Caller's responsibility to ensure a and b have had zeroUnused applied for correctness
float cellDot(CellVec v, CellVec w) {
    float sum = 0;
    for (uint i = 0; i < N_VEC4; i++) {
        sum += dot(v.vecs[i], w.vecs[i]);
    }
    return sum;
}

CellVec cellScale(float c, CellVec v) {
    CellVec result;
    for (uint i = 0; i < N_VEC4; i++) {
        result.vecs[i] = v.vecs[i] * c;
    }
    return result;
}

CellVec cellAdd(CellVec v, CellVec w) {
    CellVec result;
    for (uint i = 0; i < N_VEC4; i++) {
        result.vecs[i] = v.vecs[i] + w.vecs[i];
    }
    return result;
}

CellVec cellSub(CellVec v, CellVec w) {
    CellVec result;
    for (uint i = 0; i < N_VEC4; i++) {
        result.vecs[i] = v.vecs[i] - w.vecs[i];
    }
    return result;
}

// Mask of the positive and negative space of a glyph.
struct Mask {
    CellVec neg;
    CellVec pos;
};

// Equation params solely dependendent on the glyph, calculated offline.
// See README.md for derivation.
struct ColorEquation {
    float negneg;
    float pospos;
    float negpos;
    float determinant;
};

layout(std430, set = 0, binding = 0) buffer Masks { Mask[] masks; };
layout(std430, set = 0, binding = 1) buffer Codepoints { uint[] codepoints; };
layout(std430, set = 0, binding = 2) buffer ColorEquations { ColorEquation[] color_eqns; };

struct UnicodePixel {
    uint8_t br, bg, bb, fr, fg, fb;
    uint8_t _pad1, _pad2;
    uint codepoint;
};

layout(std430, set = 1, binding = 0) buffer InputImage { uint8_t[] rgb; };
layout(std430, set = 1, binding = 1) buffer OutputImage { UnicodePixel[] pixels; };

layout(push_constant) uniform PushConstants {
    uint num_codepoints;

    uint out_im_w;

    // subarea of image dispatch covers
    uint dispatch_x;
    uint dispatch_y;
    uint dispatch_w;
    uint dispatch_h;

    // bytes-per-pixel: number of color channels - only supports 3 or 4 currently
    uint input_bpp;

    // indices to shuffle by (swizzling) - cell set to 3 will be ignored as we don't use alpha, just rgb.
    // the swizzle from bgra to rgb would be: [ 2, 1, 0 ].
    ivec3 swizzle;

    // input image pixels per cell
    uint cell_pix_w;
    uint cell_pix_h;

    uint cell_cols;
    uint cell_rows;
} pc;

struct ImageCell {
    CellVec rgb[3];
};

vec2 solveChannel(uint mask_idx, ColorEquation eqn, CellVec cell_channel) {
    float mn_dot_p = cellDot(masks[mask_idx].neg, cell_channel);
    float mp_dot_p = cellDot(masks[mask_idx].pos, cell_channel);
    float back_color_num = mn_dot_p * eqn.pospos - mp_dot_p * eqn.negpos;
    float fore_color_num = mp_dot_p * eqn.negneg - mn_dot_p * eqn.negpos;
    return vec2(clamp(back_color_num / eqn.determinant, 0.0, 255.0),
                clamp(fore_color_num / eqn.determinant, 0.0, 255.0));
}

// Each invocation responsible for computing one terminal cell
void main() {
    const uint local_idx = gl_GlobalInvocationID.x;
    if (local_idx >= pc.dispatch_w * pc.dispatch_h) return;

    const uint out_x = (local_idx % pc.dispatch_w) + pc.dispatch_x;
    const uint out_y = (local_idx / pc.dispatch_w) + pc.dispatch_y;
    const uint out_idx = out_y * pc.out_im_w + out_x;

    const uint in_x = out_x * pc.cell_pix_w;
    const uint in_y = out_y * pc.cell_pix_h;
    const uint in_im_w = pc.out_im_w * pc.cell_pix_w;

    // Sample pixels from input image into cell
    ImageCell cell;
    zeroUnused(cell.rgb[0]);
    zeroUnused(cell.rgb[1]);
    zeroUnused(cell.rgb[2]);
    for (uint row = 0; row < pc.cell_rows; row++) {
        const uint row_base = (in_y + row) * in_im_w + in_x;
        for (uint col = 0; col < pc.cell_cols; col++) {
            uint src_col = col * pc.cell_pix_w / pc.cell_cols;
            uint byte_off = (row_base + src_col) * pc.input_bpp;
            for (uint c = 0; c < 3; c++) {
                float val = float(rgb[byte_off + pc.swizzle[c]]);
                setValue(cell.rgb[c], col, row, val);
            }
        }
    }

    uint best_i = 0;
    float best_mse = 10000000.0;
    for (uint i = 0; i < pc.num_codepoints; i++) {
        zeroUnused(masks[i].neg);
        zeroUnused(masks[i].pos);

        float mse = 0;
        for (uint c = 0; c < 3; c++) {
            vec2 back_fore_opt = solveChannel(i, color_eqns[i], cell.rgb[c]);

            CellVec back_comp = cellScale(back_fore_opt.x, masks[i].neg);
            CellVec fore_comp = cellScale(back_fore_opt.y, masks[i].pos);
            CellVec err = cellSub(cellAdd(back_comp, fore_comp), cell.rgb[c]);

            mse += cellDot(err, err);
        }

        best_i = (mse < best_mse) ? i : best_i;
        best_mse = min(mse, best_mse);
    }

    // Recomputing colors for best_i avoids branching in the main loop.
    // Conditionally copying a vec2[3] into a 'best rgb solved' variable
    // is a full branch, versus conditionally storing a usize into 'best_i',
    // which reduces to a conditional move instruction. (I think)

    // TODO: profile it to be sure

    vec2 r_solved = solveChannel(best_i, color_eqns[best_i], cell.rgb[0]);
    vec2 g_solved = solveChannel(best_i, color_eqns[best_i], cell.rgb[1]);
    vec2 b_solved = solveChannel(best_i, color_eqns[best_i], cell.rgb[2]);
    pixels[out_idx] = UnicodePixel(
        uint8_t(r_solved.x),
        uint8_t(g_solved.x),
        uint8_t(b_solved.x),
        uint8_t(r_solved.y),
        uint8_t(g_solved.y),
        uint8_t(b_solved.y),
        uint8_t(0), uint8_t(0), // padding
        codepoints[best_i]
    );
}
