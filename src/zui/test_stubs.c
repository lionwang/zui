//! Link-time stubs for the zsk Skia C ABI.
//!
//! The unit tests exercise the layout engine and the reconciler with rect-only
//! trees, so no Skia code ever runs - but those modules reference the zsk
//! symbols, and the test binary links against these no-ops instead of the real
//! (GPU-dependent) Skia libraries. Every stub is unreachable in the tests.
//!
//! NOTE: the parameter lists intentionally differ from zsk.h; C does not mangle
//! argument types into the symbol name, so the definitions still satisfy the
//! linker. The real signatures live in `src/zsk.h`.

#define STUB_VOID(name) void name(void) {}
#define STUB_PTR(name) void* name(void) { return 0; }
#define STUB_INT(name) int name(void) { return 0; }
#define STUB_FLOAT(name) float name(void) { return 0.0f; }

STUB_PTR(zsk_context_create_gl)
STUB_VOID(zsk_context_destroy)
STUB_VOID(zsk_context_purge_caches)
STUB_PTR(zsk_surface_wrap_gl)
STUB_VOID(zsk_surface_destroy)
STUB_PTR(zsk_surface_canvas)
STUB_VOID(zsk_surface_flush_and_submit)
STUB_VOID(zsk_canvas_save)
STUB_VOID(zsk_canvas_restore)
STUB_INT(zsk_canvas_save_count)
STUB_VOID(zsk_canvas_restore_to_count)
STUB_VOID(zsk_canvas_translate)
STUB_VOID(zsk_canvas_scale)
STUB_VOID(zsk_canvas_clip_rect)
STUB_VOID(zsk_canvas_clip_rrect)
STUB_VOID(zsk_canvas_clear)
STUB_VOID(zsk_canvas_draw_rect)
STUB_VOID(zsk_canvas_draw_rrect)
STUB_VOID(zsk_canvas_draw_path)
STUB_VOID(zsk_canvas_draw_image)
STUB_VOID(zsk_canvas_draw_paragraph)
STUB_PTR(zsk_paint_create)
STUB_VOID(zsk_paint_destroy)
STUB_VOID(zsk_paint_set_color)
STUB_VOID(zsk_paint_set_style)
STUB_VOID(zsk_paint_set_stroke_width)
STUB_VOID(zsk_paint_set_aa)
STUB_VOID(zsk_paint_set_blend_mode)
STUB_VOID(zsk_paint_set_alpha)
STUB_PTR(zsk_path_create)
STUB_VOID(zsk_path_destroy)
STUB_VOID(zsk_path_move_to)
STUB_VOID(zsk_path_line_to)
STUB_VOID(zsk_path_quad_to)
STUB_VOID(zsk_path_cubic_to)
STUB_VOID(zsk_path_close)
STUB_VOID(zsk_path_add_rrect)
STUB_PTR(zsk_image_make_from_encoded)
STUB_PTR(zsk_image_make_from_file)
STUB_VOID(zsk_image_destroy)
STUB_VOID(zsk_image_size)
STUB_PTR(zsk_fontcollection_create)
STUB_VOID(zsk_fontcollection_destroy)
STUB_PTR(zsk_paragraph_builder_create)
STUB_VOID(zsk_paragraph_builder_destroy)
STUB_VOID(zsk_paragraph_builder_push_style)
STUB_VOID(zsk_paragraph_builder_pop)
STUB_VOID(zsk_paragraph_builder_add_text)
STUB_PTR(zsk_paragraph_builder_build)
STUB_VOID(zsk_paragraph_destroy)
STUB_VOID(zsk_paragraph_layout)
STUB_FLOAT(zsk_paragraph_width)
STUB_FLOAT(zsk_paragraph_height)
STUB_FLOAT(zsk_paragraph_min_intrinsic_width)
STUB_FLOAT(zsk_paragraph_max_intrinsic_width)
STUB_FLOAT(zsk_paragraph_alphabetic_baseline)
STUB_INT(zsk_paragraph_line_count)
STUB_INT(zsk_millis)
STUB_INT(zsk_encode_png)
STUB_VOID(zsk_init_crt)
STUB_INT(zsk_paragraph_glyph_position)
STUB_INT(zsk_paragraph_rects_for_range)
STUB_INT(zsk_clipboard_set_text)
STUB_INT(zsk_clipboard_get_text)
