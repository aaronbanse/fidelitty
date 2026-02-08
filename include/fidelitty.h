// =============== C API ================

#include <stdint.h>

// =============== Core (headless) ================

typedef struct ftty_context_t ftty_context_t;

typedef struct ftty_pipeline_t ftty_pipeline_t;

typedef struct {
  uint8_t br, bg, bb;
  uint8_t fr, fg, fb;
  uint16_t _pad;
  uint32_t codepoint;
} ftty_unicode_pixel_t;

// Context
ftty_context_t* ftty_context_create(uint8_t max_pipelines);

void ftty_context_destroy(ftty_context_t* ctx);

// Render Pipelines
ftty_pipeline_t* ftty_context_create_render_pipeline(ftty_context_t* ctx, uint16_t w, uint16_t h);

void ftty_context_destroy_render_pipeline(ftty_context_t* ctx, ftty_pipeline_t* handle);

int ftty_context_resize_render_pipeline(ftty_context_t* ctx, ftty_pipeline_t* handle, uint16_t w, uint16_t h);

int ftty_context_execute_render_pipeline_all(ftty_context_t* ctx, ftty_pipeline_t* handle);

int ftty_context_execute_render_pipeline_region(ftty_context_t* ctx, ftty_pipeline_t* handle,
                                                uint16_t dispatch_x, uint16_t dispatch_y,
                                                uint16_t dispatch_w, uint16_t dispatch_h);

int ftty_context_wait_render_pipeline(ftty_context_t* ctx, ftty_pipeline_t* handle);

// Pipeline I/O
void ftty_pipeline_get_dims(ftty_pipeline_t* handle, uint16_t* w, uint16_t* h);

uint8_t* ftty_pipeline_get_input_surface(ftty_pipeline_t* handle);

ftty_unicode_pixel_t* ftty_pipeline_get_output_surface(ftty_pipeline_t* handle);

// Dataset Config
uint8_t ftty_get_patch_width(void);

uint8_t ftty_get_patch_height(void);

// =============== Terminal frontend ================
// NOTE: The terminal frontend is experimental and has known bugs.

typedef struct ftty_unicode_image_t ftty_unicode_image_t;

// Unicode Images
ftty_unicode_image_t* ftty_unicode_image_create(uint16_t w, uint16_t h);

void ftty_unicode_image_destroy(ftty_unicode_image_t* img);

int ftty_unicode_image_resize(ftty_unicode_image_t* img, uint16_t w, uint16_t h);

void ftty_unicode_image_set_pos(ftty_unicode_image_t* img, uint16_t x, uint16_t h);

void ftty_unicode_image_read_pixels(ftty_unicode_image_t* img, ftty_unicode_pixel_t* pixels);

void ftty_unicode_image_read_pixels_region(ftty_unicode_image_t* img, ftty_unicode_pixel_t* pixels,
                                           uint16_t x, uint16_t y, uint16_t w, uint16_t h);

int ftty_unicode_image_draw(ftty_unicode_image_t* img);

int ftty_unicode_image_draw_region(ftty_unicode_image_t* img,
                                   uint16_t x, uint16_t y, uint16_t w, uint16_t h);

// Terminal Utilities
typedef struct {
  uint16_t cols, rows, cell_w, cell_h;
} ftty_term_dims_t;

typedef struct {
  uint16_t row, col;
} ftty_cursor_pos_t;

ftty_term_dims_t ftty_terminal_get_dims(void);

int ftty_terminal_reserve_vertical_space(uint16_t rows);

int ftty_terminal_get_cursor_pos(ftty_cursor_pos_t* pos);

