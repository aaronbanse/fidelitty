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
} pc;

// RGB values of a 4x4 patch of the input image. One processed per invocation
struct Patch {
  vec4[4] r;
  vec4[4] g;
  vec4[4] b;
};

// dot product for vec16s represented as 4 vec4s
float dot16(const vec4[4] a, const vec4[4] b) {
  return dot(a[0], b[0]) + dot(a[1], b[1]) + dot(a[2], b[2]) + dot(a[3], b[3]);
}

vec2 solveChannel(const Mask mask, const ColorEquation eqn, const vec4[4] p_channel) {
  float back_color_num = dot16(mask.neg, p_channel) * eqn.pospos - dot16(mask.pos, p_channel) * eqn.negpos;
  float fore_color_num = dot16(mask.pos, p_channel) * eqn.negneg - dot16(mask.neg, p_channel) * eqn.negpos;
  return vec2(clamp(back_color_num / eqn.determinant, 0.0, 1.0), clamp(fore_color_num / eqn.determinant, 0.0, 1.0));
}

// We dispatch one invocation for each output pixel.
// Therefore each invocation is responsible for the corresponding 4x4 patch in the input image,
// and writing to that pixel in the output image.
void main() {
  // challenges: need to convert uint8_t to floats and pack into vectors for fast arithmetic
  // then we need to figure out the packing on unicodePixels
  // identify patch we're working on

  // Calculate indices
  const uint out_idx = gl_GlobalInvocationID.x;
  const uint out_x = out_idx % pc.out_im_w;
  const uint out_y = out_idx / pc.out_im_w;

  const uint in_x = out_x * 4;
  const uint in_y = out_y * 4;
  const uint in_im_w = pc.out_im_w * 4;
  
  // collect pixel data for patch
  Patch p;
  for (uint j = 0; j < 4; j++) { // iterate through rows
    const uint in_idx = (in_y + j) * in_im_w + in_x;
    p.r[j] = vec4(
      float(rgb[(in_idx + 0) * 3 + 0]),
      float(rgb[(in_idx + 1) * 3 + 0]),
      float(rgb[(in_idx + 2) * 3 + 0]),
      float(rgb[(in_idx + 3) * 3 + 0])
    );
    p.g[j] = vec4(
      float(rgb[(in_idx + 0) * 3 + 1]),
      float(rgb[(in_idx + 1) * 3 + 1]),
      float(rgb[(in_idx + 2) * 3 + 1]),
      float(rgb[(in_idx + 3) * 3 + 1])
    );
    p.b[j] = vec4(
      float(rgb[(in_idx + 0) * 3 + 2]),
      float(rgb[(in_idx + 1) * 3 + 2]),
      float(rgb[(in_idx + 2) * 3 + 2]),
      float(rgb[(in_idx + 3) * 3 + 2])
    );
  }

  // Compute best unicode character and pixel
  uint best_i = 0;
  float best_diff = 1000000.0;
  for (int i = 0; i < pc.num_codepoints; i++) {
    // find optimal colors for this glyph / patch pair
    vec2 r_solved = solveChannel(masks[i], color_eqns[i], p.r);
    vec2 g_solved = solveChannel(masks[i], color_eqns[i], p.g);
    vec2 b_solved = solveChannel(masks[i], color_eqns[i], p.b);

    // reconstruct patch using glyph neg / pos and these optimal colors
    float diff = 0;
    for (uint row = 0; row < 4; row++) {
      // TODO: figure out element-wise subtraction + reduce op
      vec4 r_err = r_solved.x*masks[i].neg[row] + r_solved.y*masks[i].pos[row] - p.r[row];
      vec4 g_err = g_solved.x*masks[i].neg[row] + g_solved.y*masks[i].pos[row] - p.g[row];
      vec4 b_err = b_solved.x*masks[i].neg[row] + b_solved.y*masks[i].pos[row] - p.b[row];
      diff += dot(r_err, r_err) + dot(g_err, g_err) + dot(b_err, b_err); // SE
    }

    best_i = (diff < best_diff) ? i : best_i;
    best_diff = min(diff, best_diff);
  }

  // recomputing colors for best i avoids either branching in main loop or allocating space to save all computed pixels,
  // cheap to: require add a single computation to 500
  vec2 r_solved = solveChannel(masks[best_i], color_eqns[best_i], p.r);
  vec2 g_solved = solveChannel(masks[best_i], color_eqns[best_i], p.g);
  vec2 b_solved = solveChannel(masks[best_i], color_eqns[best_i], p.b);
  pixels[out_idx] = UnicodePixel(
    uint8_t(r_solved.x * 255.0),
    uint8_t(g_solved.x * 255.0),
    uint8_t(b_solved.x * 255.0),
    uint8_t(r_solved.y * 255.0),
    uint8_t(g_solved.y * 255.0),
    uint8_t(b_solved.y * 255.0),
    uint8_t(0), uint8_t(0), // padding
    codepoints[best_i]
  );
  // pixels[out_idx] = UnicodePixel(
  //   uint8_t(255),
  //   uint8_t(255),
  //   uint8_t(255),
  //   uint8_t(255),
  //   uint8_t(255),
  //   uint8_t(255),
  //   uint8_t(0), uint8_t(0), // padding
  //   0x2588
  // );
}

