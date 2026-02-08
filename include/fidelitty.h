// =============== C API ================

typedef struct ftty_context_t ftty_context_t;

typedef struct ftty_pipeline_t ftty_pipeline_t;

typedef struct ftty_unicode_image_t ftty_unicode_image_t;

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

int ftty_context_execute_render_pipeline(ftty_context_t* ctx, ftty_pipeline_t* handle);

int ftty_context_wait_render_pipeline(ftty_context_t* ctx, ftty_pipeline_t* handle);

// Pipeline I/O
void ftty_pipeline_get_dims(ftty_pipeline_t* handle, uint16_t* w, uint16_t* h);

uint8_t* ftty_pipeline_get_input_surface(ftty_pipeline_t* handle);

ftty_unicode_pixel_t* ftty_pipeline_get_output_surface(ftty_pipeline_t* handle);

// Unicode Images - terminal frontend
ftty_unicode_image_t* ftty_unicode_image_create(uint16_t w, uint16_t h);

void ftty_unicode_image_destroy(ftty_unicode_image_t* img);

int ftty_unicode_image_resize(ftty_unicode_image_t* img, uint16_t w, uint16_t h);

void ftty_unicode_image_set_pos(ftty_unicode_image_t* img, uint16_t x, uint16_t h);

void ftty_unicode_image_read_pixels(ftty_unicode_image_t* img, ftty_unicode_pixel_t* pixels);

int ftty_unicode_image_draw(ftty_unicode_image_t* img);

