#version 450

layout(local_size_x = 64) in;

struct Mask {

};

struct ColorEquation {

};

layout(set = 0, binding = 0) buffer Codepoints { uint[] codepoints; };
layout(set = 0, binding = 1) buffer Masks { Mask[] masks; };
layout(set = 0, binding = 2) buffer ColorEquations { ColorEquation[] color_eqns; };

struct UnicodePixel {

};

layout(set = 1, binding = 0) buffer InputImage { uint8_t[] rgb; };
layout(set = 1, binding = 1) buffer OutputPixels { UnicodePixel[] pixels; };

void main() {
  
}

