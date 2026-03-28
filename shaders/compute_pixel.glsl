#version 450
#extension GL_EXT_shader_8bit_storage: require
#extension GL_EXT_shader_explicit_arithmetic_types_int8: require

layout(local_size_x = 64) in;

// Define a vector type for efficient operations on cells.
// Since vector ops max out at vec4, we create a custom type packed with vec4's plus a remainder vec4.
// Note that the remaining unused space in the last vec4 contains garbage values and effects
// the result of dot products and other reduction operations.

#if !defined(VEC4_QUOTIENT) || !defined(VEC4_REMAINDER) || !defined(CELL_W) || !defined(CELL_H)
    #error "Must define VEC4_QUOTIENT, VEC4_REMAINDER, CELL_W, and CELL_H when compiling"
#endif

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

// All operations producing a new CellVec are safe to be used without applying zeroUnused.

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

// Mask with values [0,1] representing the anti-aliased positive and negative space of a font glyph, compressed to 4x4.
// Element-wise sum of neg_space + pos_space is a vector of all 1.0's.
struct Mask {
  CellVec neg;
  CellVec pos;
};

// Precomputed dot products of the mask elements used in computation.
// Values can be computed offline so we cache them to speed things up.
// Determinant is of a matrix used in the formula seen below, see README.md for derivation.
struct ColorEquation {
  float negneg;
  float pospos;
  float negpos;
  float determinant;
};

layout(std430, set = 0, binding = 0) buffer Masks { Mask[] masks; };
layout(std430, set = 0, binding = 1) buffer Codepoints { uint[] codepoints; };
layout(std430, set = 0, binding = 2) buffer ColorEquations { ColorEquation[] color_eqns; };

// Size: 12
// Alignment: 4
struct UnicodePixel {
  uint8_t br, bg, bb, fr, fg, fb;
  uint8_t _pad1, _pad2;
  uint codepoint;
};

// Input and output buffers
layout(std430, set = 1, binding = 0) buffer InputImage { uint8_t[] rgb; };
layout(std430, set = 1, binding = 1) buffer OutputImage { UnicodePixel[] pixels; };

// Constants
layout(push_constant) uniform PushConstants {
    uint num_codepoints;

    uint out_im_w;

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
    uint input_cell_w;
    uint input_cell_h;

    // virtual pixels per cell
    uint cell_w;
    uint cell_h;
} pc;

struct ImageCell {
  CellVec r;
  CellVec g;
  CellVec b;
};

vec2 solveChannel(uint mask_idx, ColorEquation eqn, CellVec cell_channel) {
  float mn_dot_p = cellDot(masks[mask_idx].neg, cell_channel);
  float mp_dot_p = cellDot(masks[mask_idx].pos, cell_channel);
  float back_color_num = mn_dot_p * eqn.pospos - mp_dot_p * eqn.negpos;
  float fore_color_num = mp_dot_p * eqn.negneg - mn_dot_p * eqn.negpos;
  return vec2(clamp(back_color_num / eqn.determinant, 0.0, 255.0),
              clamp(fore_color_num / eqn.determinant, 0.0, 255.0));
}

// We dispatch one invocation for each output pixel.
// Therefore each invocation is responsible for the corresponding 4x4 patch in the input image,
// and writing to that pixel in the output image.
void main() {
  // Calculate indices within dispatch region
  const uint local_idx = gl_GlobalInvocationID.x;
  if (local_idx >= pc.dispatch_w * pc.dispatch_h) return;

  const uint out_x = (local_idx % pc.dispatch_w) + pc.dispatch_x;
  const uint out_y = (local_idx / pc.dispatch_w) + pc.dispatch_y;
  const uint out_idx = out_y * pc.out_im_w + out_x;

  const uint in_x = out_x * pc.input_cell_w;
  const uint in_y = out_y * pc.input_cell_h;
  const uint in_im_w = pc.out_im_w * pc.input_cell_w;

  // collect pixel data for patch
  // For each of the pc.patch_w patch columns, find source pixel via nearest-neighbor
  ImageCell cell;
  zeroUnused(cell.r);
  zeroUnused(cell.g);
  zeroUnused(cell.b);
  for (uint row = 0; row < pc.cell_h; row++) {
    const uint row_base = (in_y + row) * in_im_w + in_x;
    for (uint col = 0; col < pc.cell_w; col++) {
      uint src_col = col * pc.input_cell_w / pc.cell_w;
      uint byte_off = (row_base + src_col) * pc.input_bpp;
      setValue(cell.r, col, row, float(rgb[byte_off + pc.swizzle[0]]));
      setValue(cell.g, col, row, float(rgb[byte_off + pc.swizzle[1]]));
      setValue(cell.b, col, row, float(rgb[byte_off + pc.swizzle[2]]));
    }
  }

  // Compute best unicode character and pixel
  uint best_i = 0;
  float best_mse = 1000000.0;
  for (uint i = 0; i < pc.num_codepoints; i++) {
    zeroUnused(masks[i].neg);
    zeroUnused(masks[i].pos);
    // find optimal colors for this glyph / patch pair
    vec2 r_solved = solveChannel(i, color_eqns[i], cell.r);
    vec2 g_solved = solveChannel(i, color_eqns[i], cell.g);
    vec2 b_solved = solveChannel(i, color_eqns[i], cell.b);

    // reconstruct patch using glyph neg / pos and these optimal colors
    CellVec r_err = cellSub(cellAdd(cellScale(r_solved.x, masks[i].neg), cellScale(r_solved.y, masks[i].pos)), cell.r);
    CellVec g_err = cellSub(cellAdd(cellScale(g_solved.x, masks[i].neg), cellScale(g_solved.y, masks[i].pos)), cell.g);
    CellVec b_err = cellSub(cellAdd(cellScale(b_solved.x, masks[i].neg), cellScale(b_solved.y, masks[i].pos)), cell.b);
    const float mse = cellDot(r_err, r_err) + cellDot(g_err, g_err) + cellDot(b_err, b_err);

    best_i = (mse < best_mse) ? i : best_i;
    best_mse = min(mse, best_mse);
  }

  // recomputing colors for best i avoids either branching in main loop or allocating space to save all computed pixels,
  // cheap to add a single computation to 500
  vec2 r_solved = solveChannel(best_i, color_eqns[best_i], cell.r);
  vec2 g_solved = solveChannel(best_i, color_eqns[best_i], cell.g);
  vec2 b_solved = solveChannel(best_i, color_eqns[best_i], cell.b);
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
