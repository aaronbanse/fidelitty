#version 450
#extension GL_EXT_shader_8bit_storage: require
#extension GL_EXT_shader_explicit_arithmetic_types_int8: require

layout(local_size_x = 64) in;

// NOTE ON USE OF vec4[4]:
// ========================
// We are doing linear algebra on 4x4 patches- spatially 4x4,
// but they're really just 16-dimensional vectors with how the algebra treats them.
// 
// If it was supported, we would represent them using vec16, but we have to break up
// computations into 4 vec4 computations instead. It's highly possible that the compiler
// is able to generate an equivalently efficient operation, but I haven't tested it.
// ========================

// Mask with values [0,1] representing the anti-aliased positive and negative space of a font glyph, compressed to 4x4.
// Element-wise sum of neg_space + pos_space is a vector of all 1.0's.
struct Mask {
  vec4[4] neg;
  vec4[4] pos;
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

layout(std430, set = 0, binding = 0) buffer Codepoints { uint[] codepoints; };
layout(std430, set = 0, binding = 1) buffer Masks { Mask[] masks; };
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
    uint input_bpp;      // bytes-per-pixel: number of color channels - only supports 3 or 4 currently
    ivec3 swizzle;       // indices to shuffle by (swizzling) - cell set to 3 will be ignored as we don't use alpha, just rgb.
                         // the swizzle from bgra to rgb would be: [ 2, 1, 0 ].
    uint input_cell_w;   // source pixels per cell horizontally
    uint input_cell_h;   // source pixels per cell vertically
    uint patch_w;        // output patch width (from glyph dataset config)
    uint patch_h;        // output patch height (from glyph dataset config)
} pc;

// RGB values of a patch_w x patch_h patch of the input image. One processed per invocation
struct Patch {
  vec4[4] r;
  vec4[4] g;
  vec4[4] b;
};

// dot product for vec16s represented as 4 vec4s
float dot16(const vec4[4] a, const vec4[4] b) {
  return dot(a[0], b[0]) + dot(a[1], b[1]) + dot(a[2], b[2]) + dot(a[3], b[3]);
}

vec2 solveChannel(const uint mask_idx, const ColorEquation eqn, const vec4[4] p_channel) {
  float back_color_num = dot16(masks[mask_idx].neg, p_channel) * eqn.pospos - dot16(masks[mask_idx].pos, p_channel) * eqn.negpos;
  float fore_color_num = dot16(masks[mask_idx].pos, p_channel) * eqn.negneg - dot16(masks[mask_idx].neg, p_channel) * eqn.negpos;
  return vec2(clamp(back_color_num / eqn.determinant, 0.0, 255.0), clamp(fore_color_num / eqn.determinant, 0.0, 255.0));
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
  Patch p;
  for (uint j = 0; j < pc.patch_h; j++) {
    const uint row_base = (in_y + j) * in_im_w + in_x;
    for (uint col = 0; col < pc.patch_w; col++) {
      uint src_col = col * pc.input_cell_w / pc.patch_w;
      uint byte_off = (row_base + src_col) * pc.input_bpp;
      p.r[j][col] = float(rgb[byte_off + pc.swizzle[0]]);
      p.g[j][col] = float(rgb[byte_off + pc.swizzle[1]]);
      p.b[j][col] = float(rgb[byte_off + pc.swizzle[2]]);
    }
  }

  // Compute best unicode character and pixel
  uint best_i = 0;
  float best_diff = 1000000.0;
  for (uint i = 0; i < pc.num_codepoints; i++) {
    // find optimal colors for this glyph / patch pair
    vec2 r_solved = solveChannel(i, color_eqns[i], p.r);
    vec2 g_solved = solveChannel(i, color_eqns[i], p.g);
    vec2 b_solved = solveChannel(i, color_eqns[i], p.b);

    // reconstruct patch using glyph neg / pos and these optimal colors
    float diff = 0;
    for (uint row = 0; row < pc.patch_h; row++) {
      vec4 r_err = r_solved.x*masks[i].neg[row] + r_solved.y*masks[i].pos[row] - p.r[row];
      vec4 g_err = g_solved.x*masks[i].neg[row] + g_solved.y*masks[i].pos[row] - p.g[row];
      vec4 b_err = b_solved.x*masks[i].neg[row] + b_solved.y*masks[i].pos[row] - p.b[row];
      diff += dot(r_err, r_err) + dot(g_err, g_err) + dot(b_err, b_err); // SE
    }

    best_i = (diff < best_diff) ? i : best_i;
    best_diff = min(diff, best_diff);
  }

  // recomputing colors for best i avoids either branching in main loop or allocating space to save all computed pixels,
  // cheap to add a single computation to 500
  vec2 r_solved = solveChannel(best_i, color_eqns[best_i], p.r);
  vec2 g_solved = solveChannel(best_i, color_eqns[best_i], p.g);
  vec2 b_solved = solveChannel(best_i, color_eqns[best_i], p.b);
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

