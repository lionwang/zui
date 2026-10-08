// zsk - a thin C ABI over the parts of Skia that zui needs.
//
// The implementation (zsk.cpp) is compiled with MSVC against Skia's C++ headers;
// the Zig side of zui consumes this header through `addTranslateC` in build.zig.
#ifndef ZSK_H
#define ZSK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* GPU context & surfaces                                              */
/* ------------------------------------------------------------------ */

typedef struct zsk_context zsk_context;
typedef struct zsk_surface zsk_surface;
typedef struct zsk_canvas zsk_canvas;
typedef struct zsk_paint zsk_paint;
typedef struct zsk_path zsk_path;
typedef struct zsk_image zsk_image;
typedef struct zsk_fontcollection zsk_fontcollection;
typedef struct zsk_paragraph_builder zsk_paragraph_builder;
typedef struct zsk_paragraph zsk_paragraph;

// Creates a GrDirectContext bound to the current WGL OpenGL context.
zsk_context* zsk_context_create_gl(void);
void zsk_context_destroy(zsk_context*);
// Frees all GPU resources held by the context.
void zsk_context_purge_caches(zsk_context*);

// Wraps the given OpenGL framebuffer (0 = the window's default framebuffer)
// into an SkSurface rendered with `zsk_context`.
zsk_surface* zsk_surface_wrap_gl(zsk_context* ctx, int width, int height,
                                 int sample_count, int stencil_bits,
                                 uint32_t framebuffer);
void zsk_surface_destroy(zsk_surface*);
int zsk_surface_read_pixels(zsk_surface* s, void* rgba, int width, int height);
zsk_canvas* zsk_surface_canvas(zsk_surface*);
// Makes the surface's contents visible on the wrapped framebuffer.
void zsk_surface_flush_and_submit(zsk_surface*);

/* ------------------------------------------------------------------ */
/* Canvas                                                              */
/* ------------------------------------------------------------------ */

void zsk_canvas_save(zsk_canvas*);
void zsk_canvas_restore(zsk_canvas*);
int zsk_canvas_save_count(zsk_canvas*);
void zsk_canvas_restore_to_count(zsk_canvas*, int count);
void zsk_canvas_translate(zsk_canvas*, float x, float y);
void zsk_canvas_scale(zsk_canvas*, float x, float y);
void zsk_canvas_clip_rect(zsk_canvas*, float l, float t, float r, float b, int do_aa);
void zsk_canvas_clip_rrect(zsk_canvas*, float l, float t, float r, float b,
                           float rx, float ry, int do_aa);
void zsk_canvas_clear(zsk_canvas*, uint32_t color);
void zsk_canvas_draw_rect(zsk_canvas*, float l, float t, float r, float b, const zsk_paint*);
void zsk_canvas_draw_rrect(zsk_canvas*, float l, float t, float r, float b,
                           float rx, float ry, const zsk_paint*);
void zsk_canvas_draw_path(zsk_canvas*, const zsk_path*, const zsk_paint*);
void zsk_canvas_draw_image(zsk_canvas*, const zsk_image*, float x, float y, const zsk_paint*);
void zsk_canvas_draw_paragraph(zsk_canvas*, const zsk_paragraph*, float x, float y);

/* ------------------------------------------------------------------ */
/* Paint                                                               */
/* ------------------------------------------------------------------ */

// paint style
enum zsk_paint_style {
    ZSK_FILL = 0,
    ZSK_STROKE = 1,
    ZSK_FILL_AND_STROKE = 2,
};
// blend modes (subset)
enum zsk_blend_mode {
    ZSK_BLEND_CLEAR = 0,
    ZSK_BLEND_SRC = 1,
    ZSK_BLEND_DST = 2,
    ZSK_BLEND_SRC_OVER = 3,
    ZSK_BLEND_DST_OVER = 4,
    ZSK_BLEND_SRC_IN = 5,
    ZSK_BLEND_DST_IN = 6,
    ZSK_BLEND_SRC_OUT = 7,
    ZSK_BLEND_DST_OUT = 8,
    ZSK_BLEND_SRC_ATOP = 9,
    ZSK_BLEND_DST_ATOP = 10,
    ZSK_BLEND_XOR = 11,
    ZSK_BLEND_PLUS = 12,
    ZSK_BLEND_MODULATE = 13,
    ZSK_BLEND_SCREEN = 14,
    ZSK_BLEND_MULTIPLY = 15,
    ZSK_BLEND_DARKEN = 16,
    ZSK_BLEND_LIGHTEN = 17,
};

zsk_paint* zsk_paint_create(void);
void zsk_paint_destroy(zsk_paint*);
void zsk_paint_set_color(zsk_paint*, uint32_t argb);
void zsk_paint_set_style(zsk_paint*, int style);
void zsk_paint_set_stroke_width(zsk_paint*, float width);
void zsk_paint_set_aa(zsk_paint*, int enabled);
void zsk_paint_set_blend_mode(zsk_paint*, int mode);
void zsk_paint_set_alpha(zsk_paint*, int alpha); // 0..255

/* ------------------------------------------------------------------ */
/* Path                                                                */
/* ------------------------------------------------------------------ */

zsk_path* zsk_path_create(void);
void zsk_path_destroy(zsk_path*);
void zsk_path_move_to(zsk_path*, float x, float y);
void zsk_path_line_to(zsk_path*, float x, float y);
void zsk_path_quad_to(zsk_path*, float x1, float y1, float x2, float y2);
void zsk_path_cubic_to(zsk_path*, float x1, float y1, float x2, float y2, float x3, float y3);
void zsk_path_close(zsk_path*);
void zsk_path_add_rrect(zsk_path*, float l, float t, float r, float b, float rx, float ry);

/* ------------------------------------------------------------------ */
/* Images                                                              */
/* ------------------------------------------------------------------ */

zsk_image* zsk_image_make_from_encoded(const void* data, size_t len);
zsk_image* zsk_image_make_from_file(const char* path);
void zsk_image_destroy(zsk_image*);
void zsk_image_size(const zsk_image*, int* width, int* height);

/* ------------------------------------------------------------------ */
/* Typography (modules/skparagraph)                                    */
/* ------------------------------------------------------------------ */

enum zsk_text_align {
    ZSK_ALIGN_LEFT = 0,
    ZSK_ALIGN_RIGHT = 1,
    ZSK_ALIGN_CENTER = 2,
    ZSK_ALIGN_JUSTIFY = 3,
    ZSK_ALIGN_START = 4,
    ZSK_ALIGN_END = 5,
};
enum zsk_text_direction {
    ZSK_DIR_LTR = 0,
    ZSK_DIR_RTL = 1,
};
enum zsk_font_weight {
    ZSK_WEIGHT_THIN = 100,
    ZSK_WEIGHT_EXTRALIGHT = 200,
    ZSK_WEIGHT_LIGHT = 300,
    ZSK_WEIGHT_NORMAL = 400,
    ZSK_WEIGHT_MEDIUM = 500,
    ZSK_WEIGHT_SEMIBOLD = 600,
    ZSK_WEIGHT_BOLD = 700,
    ZSK_WEIGHT_EXTRABOLD = 800,
    ZSK_WEIGHT_BLACK = 900,
};
enum zsk_font_slant {
    ZSK_SLANT_UPRIGHT = 0,
    ZSK_SLANT_ITALIC = 1,
};
enum zsk_decoration {
    ZSK_DECOR_NONE = 0,
    ZSK_DECOR_UNDERLINE = 1,
    ZSK_DECOR_OVERLINE = 2,
    ZSK_DECOR_STRIKETHROUGH = 4,
    ZSK_DECOR_LINE_THROUGH = 4, // alias
};

typedef struct {
    uint32_t color;         // 0xAARRGGBB, ignored when < 0 (inherit)
    float font_size;        // px, <= 0 inherits
    float height_multiplier;// line height multiplier, <= 0 inherits
    float letter_spacing;   // px
    int weight;             // zsk_font_weight, < 0 inherits
    int slant;              // zsk_font_slant, < 0 inherits
    const char* font_family;// optional, nullptr = default
        int decoration;         // bitmask of zsk_decoration
    uint32_t decoration_color; // < 0 (i.e. 0xFFFFFFFF with alpha 0?) - use 0 to inherit
} zsk_text_style;

typedef struct {
    int direction;       // zsk_text_direction
    int alignment;       // zsk_text_align
    int max_lines;       // 0 = unlimited
    int ellipsis;        // 1 to ellipsize overflow
    float height_multiplier;
} zsk_paragraph_style;

// Creates a font collection backed by the platform's default font manager
// (DirectWrite on Windows).
zsk_fontcollection* zsk_fontcollection_create(void);
void zsk_fontcollection_destroy(zsk_fontcollection*);

zsk_paragraph_builder* zsk_paragraph_builder_create(zsk_fontcollection*, const zsk_paragraph_style*);
void zsk_paragraph_builder_destroy(zsk_paragraph_builder*);
void zsk_paragraph_builder_push_style(zsk_paragraph_builder*, const zsk_text_style*);
void zsk_paragraph_builder_pop(zsk_paragraph_builder*);
void zsk_paragraph_builder_add_text(zsk_paragraph_builder*, const char* utf8, size_t len);
zsk_paragraph* zsk_paragraph_builder_build(zsk_paragraph_builder*);

void zsk_paragraph_destroy(zsk_paragraph*);
void zsk_paragraph_layout(zsk_paragraph*, float width);
float zsk_paragraph_width(zsk_paragraph*);
float zsk_paragraph_height(zsk_paragraph*);
float zsk_paragraph_min_intrinsic_width(zsk_paragraph*);
float zsk_paragraph_max_intrinsic_width(zsk_paragraph*);
float zsk_paragraph_alphabetic_baseline(zsk_paragraph*);
int zsk_paragraph_line_count(zsk_paragraph*);

// Text selection support. The glyph index (in UTF-16 code units, matching
// SkParagraph) at the given paragraph-local coordinate; clamps to the text
// ends.
int zsk_paragraph_glyph_position(zsk_paragraph*, float dx, float dy);

// Bounding boxes (left, top, right, bottom quadruples) enclosing the glyphs
// between start and end (in the same units). Writes at most max_count
// quadruples; returns the number written.
int zsk_paragraph_rects_for_range(zsk_paragraph*, unsigned start, unsigned end,
                                  float* out_rects, int max_count);

/* ------------------------------------------------------------------ */
/* Clipboard                                                          */
/* ------------------------------------------------------------------ */

// Sets / gets the Windows clipboard text as UTF-8. `zsk_clipboard_get_text`
// writes at most `cap - 1` bytes and NUL-terminates; returns the byte count
// (0 on failure or when the clipboard holds no text). Opening the clipboard
// is retried for a while, since a monitoring service may hold it open.
int zsk_clipboard_set_text(const char* utf8, size_t len);
size_t zsk_clipboard_get_text(char* out_utf8, size_t cap);
// Is the clipboard currently held open by another process? A
// side-effect-free probe (opens and closes it again without touching the
// contents), for callers that prefer to skip clipboard work.
int zsk_clipboard_locked();

/* ------------------------------------------------------------------ */
/* Runtime                                                            */
/* ------------------------------------------------------------------ */

// Initializes the dynamic MSVC CRT state (onexit table + static
// initializers) that Zig's own entry point does not run. Call once before
// creating any Skia object.
void zsk_init_crt(void);

// Encodes an RGBA (0xAARRGGBB row-major, stride = width*4) buffer to a PNG
// file. Returns 1 on success. Used to produce screenshots for the docs.
int zsk_encode_png(const void* rgba, int width, int height, const char* path);

// Monotonic milliseconds since boot (GetTickCount64), for timers and
// animations (caret blinking, scheduled updates). Zig 0.16's `std.time` no
// longer exposes a wall clock without an `Io` instance, so the C ABI gives
// zui the one clock it needs.
uint64_t zsk_millis(void);
/* ---------------------------------------------------------------------- */
/* Misc                                                                */
/* ------------------------------------------------------------------ */


#ifdef __cplusplus
}
#endif
#endif // ZSK_H
