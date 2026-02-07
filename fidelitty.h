// =============== C API ================

typedef struct ftty_context_t ftty_context_t;

typedef struct ftty_pipeline_t ftty_pipeline_t;

typedef struct {
  uint8_t br, bg, bb;
  uint8_t fr, fg, fb;
  uint16_t _pad;
  uint32_t codepoint;
} ftty_unicode_pixel_t;

ftty_context_t* ftty_context_create(uint8_t max_pipelines);

void ftty_context_destroy(ftty_context_t* ctx);

ftty_pipeline_t* ftty_context_create_render_pipeline(ftty_context_t* ctx, uint16_t w, uint16_t h);

void ftty_context_destroy_render_pipeline(ftty_context_t* ctx, ftty_pipeline_t* pipeline);

int ftty_context_resize_render_pipeline(ftty_context_t* ctx, ftty_pipeline_t* pipeline, uint16_t w, uint16_t h);

int ftty_context_execute_render_pipeline(ftty_context_t* ctx, ftty_pipeline_t* pipeline);

int ftty_context_wait_render_pipeline(ftty_context_t* ctx, ftty_pipeline_t* pipeline);

void ftty_pipeline_get_dims(ftty_pipeline_t* pipeline, uint16_t* w, uint16_t* h);

uint8_t* ftty_pipeline_get_input_surface(ftty_pipeline_t* pipeline);

ftty_unicode_pixel_t* ftty_pipeline_get_output_surface(ftty_pipeline_t* pipeline);

