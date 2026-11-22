#ifndef VECTORCRAFT_BRIDGING_H
#define VECTORCRAFT_BRIDGING_H

#include <stdint.h>
#include <stddef.h>

typedef struct VCCallbacks {
    void *user;
    void (*open_files)(void *user);
    void (*place_files)(void *user);
    void (*save_file)(void *user, const char *name, const uint8_t *data, size_t len);
    void (*open_url)(void *user, const char *url);
    void (*copy_text)(void *user, const char *text);
    const char *(*paste_text)(void *user);
    void (*print_pdf)(void *user, const char *title, const uint8_t *data, size_t len);
} VCCallbacks;

void *vc_create(void *metal_layer, uint32_t width_px, uint32_t height_px, float scale, VCCallbacks cb);
void vc_destroy(void *h);
void vc_resize(void *h, uint32_t width_px, uint32_t height_px, float scale);
void vc_set_dark(void *h, int dark);
void vc_set_focused(void *h, int focused);
void vc_set_pen_seen(void *h, int seen);
void vc_toggle_eraser(void *h);

void vc_pointer_moved(void *h, float x, float y, uint32_t mods);
void vc_pointer_gone(void *h);
void vc_pointer_button(void *h, float x, float y, int button, int pressed, uint32_t mods);
void vc_scroll(void *h, float dx, float dy, uint32_t mods);
void vc_pinch(void *h, float factor);

void vc_touch(void *h, int kind, int32_t id, int phase, float x, float y, float pressure, uint32_t mods,
              float tilt_x, float tilt_y, float roll);

void vc_key(void *h, uint32_t hid, int pressed, int repeat, uint32_t mods);
void vc_text(void *h, const char *utf8);
void vc_copy(void *h);
void vc_cut(void *h);
void vc_paste(void *h, const char *utf8);

void vc_open_file(void *h, const char *name, const uint8_t *data, size_t len);
void vc_open_cancel(void *h);
void vc_place_file(void *h, const char *name, const uint8_t *data, size_t len);
void vc_drop_file(void *h, const char *name, const uint8_t *data, size_t len);

void vc_mods(void *h, uint32_t mods);
int vc_run(void *h, const char *command, const char *params_json);
const char *vc_tool_id(void *h);
int vc_has_selection(void *h);
uint32_t vc_theme_color(void *h, int which);
int vc_over_canvas(void *h, float x, float y);

int vc_frame(void *h);
void vc_save_state(void *h);

#endif
