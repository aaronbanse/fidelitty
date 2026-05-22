#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ftty_context_t ftty_context_t;

typedef struct ftty_pipeline_t ftty_pipeline_t;

typedef uint8_t ftty_pixel_format_t;
#define FTTY_PIXEL_RGB ((ftty_pixel_format_t)0)
#define FTTY_PIXEL_BGRA ((ftty_pixel_format_t)1)

typedef struct {
  uint8_t br, bg, bb;
  uint8_t fr, fg, fb;
  uint16_t _pad;
  uint32_t codepoint;
} ftty_unicode_pixel_t;

// Font generation
int ftty_init_font(const char* user_font_path);

// Context management
ftty_context_t* ftty_context_create(uint8_t max_pipelines);
void ftty_context_destroy(ftty_context_t* ctx);

// Render pipeline management
ftty_pipeline_t* ftty_context_create_render_pipeline(
    ftty_context_t* ctx,
    uint16_t grid_w, uint16_t grid_h);

ftty_pipeline_t* ftty_context_create_render_pipeline_ex(
    ftty_context_t* ctx,
    uint16_t grid_w, uint16_t grid_h,
    ftty_pixel_format_t pixel_format,
    uint8_t im_patch_w, uint8_t im_patch_h);

void ftty_context_destroy_render_pipeline(
    ftty_context_t* ctx,
    ftty_pipeline_t* handle);

int ftty_context_resize_render_pipeline(
    ftty_context_t* ctx,
    ftty_pipeline_t* handle,
    uint16_t grid_w, uint16_t grid_h);

int ftty_context_execute_render_pipeline(
    ftty_context_t* ctx,
    ftty_pipeline_t* handle);

// TODO: add a comment specifying what the units are for dispatch.
int ftty_context_execute_render_pipeline_region(
    ftty_context_t* ctx,
    ftty_pipeline_t* handle,
    uint16_t dispatch_x, uint16_t dispatch_y,
    uint16_t dispatch_w, uint16_t dispatch_h);

int ftty_context_wait_render_pipeline(
    ftty_context_t* ctx,
    ftty_pipeline_t* handle);

// Pipeline I/O
void ftty_pipeline_get_dims(
    ftty_pipeline_t* handle,
    uint16_t* grid_w, uint16_t* grid_h);

uint8_t* ftty_pipeline_get_input_surface(ftty_pipeline_t* handle);

ftty_unicode_pixel_t* ftty_pipeline_get_output_surface(ftty_pipeline_t* handle);

// Dataset Config
uint8_t ftty_get_cell_width(void);

uint8_t ftty_get_cell_height(void);

#ifdef __cplusplus
}
#endif
