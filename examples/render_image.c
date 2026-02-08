#include <stdio.h>
#include <stdint.h>

#include <fidelitty.h>

#include "stb_image.h"

int main(void) {
    // Config constants
    const uint8_t patch_w = ftty_get_patch_width();
    const uint8_t patch_h = ftty_get_patch_height();

    // set this to your desired image path
    const char *IMAGE_PATH = "examples/assets/kitty.jpg";

    // load image from disk
    fprintf(stderr, "Loading image... ");
    int img_w, img_h, img_chan_n;
    uint8_t *image_raw = stbi_load(IMAGE_PATH, &img_w, &img_h, &img_chan_n, 3);
    if (!image_raw) {
        fprintf(stderr, "Failed to load image\n");
        return 1;
    }
    fprintf(stderr, "Finished.\n");

    // initialize compute context
    ftty_context_t *ctx = ftty_context_create(8);
    if (!ctx) {
        fprintf(stderr, "Failed to create compute context\n");
        stbi_image_free(image_raw);
        return 1;
    }

    // create a render pipeline
    ftty_term_dims_t term_dims = ftty_terminal_get_dims();
    uint16_t out_image_h = term_dims.rows;
    uint16_t out_image_w = (uint16_t)((float)(term_dims.rows * term_dims.cell_h)
        * ((float)img_w / (float)img_h) / (float)term_dims.cell_w);
    ftty_pipeline_t *pipeline = ftty_context_create_render_pipeline(ctx, out_image_w, out_image_h);
    if (!pipeline) {
        fprintf(stderr, "Failed to create render pipeline\n");
        ftty_context_destroy(ctx);
        stbi_image_free(image_raw);
        return 1;
    }

    // get ratio of image size to expected input size (out image size * patch size)
    size_t exp_input_w = (size_t)out_image_w * (size_t)patch_w;
    size_t exp_input_h = (size_t)out_image_h * (size_t)patch_h;
    float x_rat = (float)img_w / (float)exp_input_w;
    float y_rat = (float)img_h / (float)exp_input_h;

    // sample from image to input surface
    uint8_t *input_surface = ftty_pipeline_get_input_surface(pipeline);
    for (size_t y = 0; y < exp_input_h; y++) {
        for (size_t x = 0; x < exp_input_w; x++) {
            size_t img_x = (size_t)((float)x * x_rat);
            size_t img_y = (size_t)((float)y * y_rat);
            size_t src_idx = (img_y * img_w + img_x) * 3;
            size_t dst_idx = (y * exp_input_w + x) * 3;
            input_surface[dst_idx + 0] = image_raw[src_idx + 0];
            input_surface[dst_idx + 1] = image_raw[src_idx + 1];
            input_surface[dst_idx + 2] = image_raw[src_idx + 2];
        }
    }

    // Init output image to fill terminal
    ftty_unicode_image_t *out_image = ftty_unicode_image_create(out_image_w, out_image_h);
    if (!out_image) {
        fprintf(stderr, "Failed to create unicode image\n");
        ftty_context_destroy_render_pipeline(ctx, pipeline);
        ftty_context_destroy(ctx);
        stbi_image_free(image_raw);
        return 1;
    }

    // reserve space on the screen for our image to avoid overwriting
    ftty_terminal_reserve_vertical_space(out_image_h);
    ftty_cursor_pos_t cursor_pos;
    ftty_terminal_get_cursor_pos(&cursor_pos);
    ftty_unicode_image_set_pos(out_image, cursor_pos.col, cursor_pos.row);

    // run pipeline
    ftty_context_execute_render_pipeline_region(ctx, pipeline,
                                                out_image_w / 2, out_image_h / 2,
                                                out_image_w / 2, out_image_h / 2);

    // wait on completion
    ftty_context_wait_render_pipeline(ctx, pipeline);

    ftty_unicode_pixel_t *output_surface = ftty_pipeline_get_output_surface(pipeline);
    ftty_unicode_image_read_pixels(out_image, output_surface);
    ftty_unicode_image_draw(out_image);

    // resize and reposition the image to overlap the other image
    uint16_t out_image_w_small = out_image_w / 2;
    uint16_t out_image_h_small = out_image_h / 2;
    ftty_terminal_reserve_vertical_space(out_image_h_small - 20);
    ftty_terminal_get_cursor_pos(&cursor_pos);
    ftty_unicode_image_set_pos(out_image, cursor_pos.col + 90, cursor_pos.row - 20);
    ftty_unicode_image_resize(out_image, out_image_w_small, out_image_h_small);

    // resize the pipeline - will be tied to the image in the future
    ftty_context_resize_render_pipeline(ctx, pipeline, out_image_w_small, out_image_h_small);

    // read in data for smaller image
    // get ratio of image size to expected input size (out image size * patch size)
    size_t exp_input_w_small = (size_t)out_image_w_small * (size_t)patch_w;
    size_t exp_input_h_small = (size_t)out_image_h_small * (size_t)patch_h;
    float x_rat_small = (float)img_w / (float)exp_input_w_small;
    float y_rat_small = (float)img_h / (float)exp_input_h_small;

    // sample from image to input surface
    input_surface = ftty_pipeline_get_input_surface(pipeline);
    for (size_t y = 0; y < exp_input_h_small; y++) {
        for (size_t x = 0; x < exp_input_w_small; x++) {
            size_t img_x = (size_t)((float)x * x_rat_small);
            size_t img_y = (size_t)((float)y * y_rat_small);
            size_t src_idx = (img_y * img_w + img_x) * 3;
            size_t dst_idx = (y * exp_input_w_small + x) * 3;
            input_surface[dst_idx + 0] = image_raw[src_idx + 0];
            input_surface[dst_idx + 1] = image_raw[src_idx + 1];
            input_surface[dst_idx + 2] = image_raw[src_idx + 2];
        }
    }

    // run pipeline
    ftty_context_execute_render_pipeline_all(ctx, pipeline);

    // wait on completion
    ftty_context_wait_render_pipeline(ctx, pipeline);

    // render
    output_surface = ftty_pipeline_get_output_surface(pipeline);
    ftty_unicode_image_read_pixels(out_image, output_surface);
    ftty_unicode_image_draw(out_image);

    // cleanup
    ftty_context_destroy_render_pipeline(ctx, pipeline);
    ftty_unicode_image_destroy(out_image);
    ftty_context_destroy(ctx);
    stbi_image_free(image_raw);

    return 0;
}
