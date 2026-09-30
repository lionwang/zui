// zsk - Skia C ABI implementation (compiled with MSVC).
#include "zsk.h"
#include <cstdio>
#include <cstring>

// ---------------------------------------------------------------------------
// CRT startup stubs.
//
// The prebuilt Skia libraries and this file are built against the dynamic
// MSVC runtime (/MD). In that model the CRT startup objects inside msvcrt.lib
// (utility.obj) reference a handful of internal `__acrt_*` / `__vcrt_*`
// routines. cl.exe normally resolves those through /alternatename directives
// that point them at the no-op `__scrt_stub_for_acrt_*` stubs in
// msvcrt.lib(ucrt_stubs.obj). Zig's build system cannot pass those linker
// directives, so we provide the equivalent no-op definitions here. They are
// semantically identical to the ones MSVC itself links in: the process is
// initialized by the normal loader path and these routines are not needed.
// ---------------------------------------------------------------------------
extern "C" {
void __acrt_initialize(void) {}
void __acrt_uninitialize(void) {}
void __acrt_uninitialize_critical(void) {}
void __acrt_thread_attach(void) {}
void __acrt_thread_detach(void) {}
void __vcrt_initialize(void) {}
void __vcrt_uninitialize(void) {}
void __vcrt_uninitialize_critical(void) {}
void __vcrt_thread_attach(void) {}
void __vcrt_thread_detach(void) {}
int _is_c_termination_complete(void) { return 0; }

// ---- Dynamic MSVC CRT startup (replayed by zsk_init_crt) ------------------
// Zig provides its own entry point, so the CRT startup object inside
// msvcrt.lib (crtexe.obj -> __scrt_common_main_seh) never executes. Two of
// its responsibilities are still needed by the prebuilt Skia libraries:
//   1. _initialize_onexit_table(): without it the onexit table is garbage and
//      the first atexit() call (Skia registers exit handlers from static
//      constructors) jumps to address 0xFFFFFFFFFFFFFFFF.
//   2. _initterm() over the .CRT$XI* / .CRT$XC* sections, which runs the C
//      and C++ static initializers of the Skia static libraries.
// The boundary markers below are allocated in the same sections the linker
// sorts all $-suffixed CRT sections into, so _initterm sees every entry that
// lives between them. This mirrors what the real CRT startup does.
typedef void (__cdecl *_zsk_PVFV)(void);

#pragma section(".CRT$XIA", long, read)
#pragma section(".CRT$XIZ", long, read)
#pragma section(".CRT$XCA", long, read)
#pragma section(".CRT$XCZ", long, read)

__declspec(allocate(".CRT$XIA")) _zsk_PVFV zsk_xi_a[] = { nullptr };
__declspec(allocate(".CRT$XIZ")) _zsk_PVFV zsk_xi_z[] = { nullptr };
__declspec(allocate(".CRT$XCA")) _zsk_PVFV zsk_xc_a[] = { nullptr };
__declspec(allocate(".CRT$XCZ")) _zsk_PVFV zsk_xc_z[] = { nullptr };

// Defined in msvcrt.lib (utility.obj): initializes this module's onexit and
// at_quick_exit tables exactly as the real CRT startup would. The argument is
// the "enclosing module" flag (0 = the main executable).
extern "C" int __cdecl __scrt_initialize_onexit_tables(int enclosing_module);
__declspec(dllimport) void __cdecl _initterm(_zsk_PVFV* first, _zsk_PVFV* last);

// Call exactly once, before any Skia object is created.
void zsk_init_crt(void) {
    __scrt_initialize_onexit_tables(0);
    _initterm(zsk_xi_a, zsk_xi_z);
    _initterm(zsk_xc_a, zsk_xc_z);
}
}


#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkImage.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkRRect.h"
#include "include/core/SkClipOp.h"
#include "include/core/SkRect.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypes.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLInterface.h"
#include "include/gpu/ganesh/gl/GrGLTypes.h"
#include "include/gpu/ganesh/gl/win/GrGLMakeWinInterface.h"
#include "include/encode/SkPngEncoder.h"
#include "include/ports/SkTypeface_win.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/ParagraphStyle.h"
#include "modules/skparagraph/include/TextStyle.h"

#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <vector>

#define ZSK_EXPORT extern "C"

struct zsk_context {
    sk_sp<GrDirectContext> ctx;
};

struct zsk_surface {
    sk_sp<SkSurface> surface;
};

struct zsk_paint {
    SkPaint paint;
};

struct zsk_path {
    SkPath path;
};

struct zsk_image {
    sk_sp<SkImage> image;
};

struct zsk_fontcollection {
    sk_sp<skia::textlayout::FontCollection> fc;
};

struct zsk_paragraph_builder {
    std::unique_ptr<skia::textlayout::ParagraphBuilder> builder;
};

struct zsk_paragraph {
    std::unique_ptr<skia::textlayout::Paragraph> paragraph;
};

/* ------------------------------------------------------------------ */
/* GPU context & surfaces                                              */
/* ------------------------------------------------------------------ */

ZSK_EXPORT zsk_context* zsk_context_create_gl(void) {
    auto iface = GrGLInterfaces::MakeWin();
    if (!iface) return nullptr;
    auto ctx = GrDirectContexts::MakeGL(iface);
    if (!ctx) return nullptr;
    auto* out = new (std::nothrow) zsk_context();
    if (!out) return nullptr;
    out->ctx = ctx;
    return out;
}

ZSK_EXPORT void zsk_context_destroy(zsk_context* c) { delete c; }

ZSK_EXPORT void zsk_context_purge_caches(zsk_context* c) {
    if (c) c->ctx->purgeUnlockedResources(GrPurgeResourceOptions::kAllResources);
}

ZSK_EXPORT zsk_surface* zsk_surface_wrap_gl(zsk_context* ctx, int width, int height,
                                            int sample_count, int stencil_bits,
                                            uint32_t framebuffer) {
    if (!ctx) return nullptr;
    GrGLFramebufferInfo info{};
    info.fFBOID = framebuffer;
    info.fFormat = 0x8058; // GL_RGBA8
    auto target = GrBackendRenderTargets::MakeGL(width, height, sample_count, stencil_bits, info);
    auto surface = SkSurfaces::WrapBackendRenderTarget(
        ctx->ctx.get(), target, kBottomLeft_GrSurfaceOrigin, kN32_SkColorType,
        nullptr, nullptr);
    if (!surface) return nullptr;
    auto* out = new (std::nothrow) zsk_surface();
    if (!out) return nullptr;
    out->surface = surface;
    return out;
}

ZSK_EXPORT void zsk_surface_destroy(zsk_surface* s) { delete s; }

// Copy the surface's pixels into gba (width*height*4 bytes, top-to-bottom).
// Returns 1 on success. Used by the render self-check.
ZSK_EXPORT int zsk_surface_read_pixels(zsk_surface* s, void* rgba, int width, int height) {
    if (!s) return 0;
    auto info = SkImageInfo::Make(width, height, kN32_SkColorType, kPremul_SkAlphaType);
    return s->surface->readPixels(info, rgba, width * 4, 0, 0) ? 1 : 0;
}

ZSK_EXPORT zsk_canvas* zsk_surface_canvas(zsk_surface* s) {
    return s ? reinterpret_cast<zsk_canvas*>(s->surface->getCanvas()) : nullptr;
}

ZSK_EXPORT void zsk_surface_flush_and_submit(zsk_surface* s) {
    if (s) skgpu::ganesh::FlushAndSubmit(s->surface.get());
}

// Encode a raw RGBA buffer (0xAARRGGBB row-major, stride = width*4) as a PNG
// file. Returns 1 on success. Used to produce screenshots for the docs.
ZSK_EXPORT int zsk_encode_png(const void* rgba, int width, int height, const char* path) {
    if (!rgba || !path) return 0;
    SkBitmap bm;
    bm.allocPixels(SkImageInfo::Make(width, height, kN32_SkColorType, kPremul_SkAlphaType));
    std::memcpy(bm.getPixels(), rgba, static_cast<size_t>(width) * height * 4);
    SkPixmap pm;
    if (!bm.peekPixels(&pm)) return 0;
    SkFILEWStream out(path);
    if (!out.isValid()) return 0;
    return SkPngEncoder::Encode(&out, pm, {}) ? 1 : 0;
}

/* ------------------------------------------------------------------ */
/* Canvas                                                              */
/* ------------------------------------------------------------------ */

static SkCanvas* as_canvas(zsk_canvas* c) { return reinterpret_cast<SkCanvas*>(c); }

ZSK_EXPORT void zsk_canvas_save(zsk_canvas* c) { as_canvas(c)->save(); }
ZSK_EXPORT void zsk_canvas_restore(zsk_canvas* c) { as_canvas(c)->restore(); }
ZSK_EXPORT int zsk_canvas_save_count(zsk_canvas* c) { return as_canvas(c)->getSaveCount(); }
ZSK_EXPORT void zsk_canvas_restore_to_count(zsk_canvas* c, int count) { as_canvas(c)->restoreToCount(count); }
ZSK_EXPORT void zsk_canvas_translate(zsk_canvas* c, float x, float y) { as_canvas(c)->translate(x, y); }
ZSK_EXPORT void zsk_canvas_scale(zsk_canvas* c, float x, float y) { as_canvas(c)->scale(x, y); }

ZSK_EXPORT void zsk_canvas_clip_rect(zsk_canvas* c, float l, float t, float r, float b, int do_aa) {
    as_canvas(c)->clipRect(SkRect::MakeLTRB(l, t, r, b), do_aa ? SkClipOp::kIntersect : SkClipOp::kIntersect, do_aa != 0);
}

ZSK_EXPORT void zsk_canvas_clip_rrect(zsk_canvas* c, float l, float t, float r, float b,
                                      float rx, float ry, int do_aa) {
    as_canvas(c)->clipRRect(SkRRect::MakeRectXY(SkRect::MakeLTRB(l, t, r, b), rx, ry),
                            SkClipOp::kIntersect, do_aa != 0);
}

ZSK_EXPORT void zsk_canvas_clear(zsk_canvas* c, uint32_t color) {
    as_canvas(c)->clear(color);
}

ZSK_EXPORT void zsk_canvas_draw_rect(zsk_canvas* c, float l, float t, float r, float b, const zsk_paint* p) {
    as_canvas(c)->drawRect(SkRect::MakeLTRB(l, t, r, b), p ? p->paint : SkPaint());
}

ZSK_EXPORT void zsk_canvas_draw_rrect(zsk_canvas* c, float l, float t, float r, float b,
                                      float rx, float ry, const zsk_paint* p) {
    as_canvas(c)->drawRRect(SkRRect::MakeRectXY(SkRect::MakeLTRB(l, t, r, b), rx, ry),
                            p ? p->paint : SkPaint());
}

ZSK_EXPORT void zsk_canvas_draw_path(zsk_canvas* c, const zsk_path* path, const zsk_paint* p) {
    as_canvas(c)->drawPath(path ? path->path : SkPath(), p ? p->paint : SkPaint());
}

ZSK_EXPORT void zsk_canvas_draw_image(zsk_canvas* c, const zsk_image* img, float x, float y, const zsk_paint* p) {
    if (!img || !img->image) return;
    as_canvas(c)->drawImage(img->image, x, y, SkSamplingOptions(), p ? &p->paint : nullptr);
}

ZSK_EXPORT void zsk_canvas_draw_paragraph(zsk_canvas* c, const zsk_paragraph* para, float x, float y) {
    if (!para || !para->paragraph) return;
    para->paragraph->paint(as_canvas(c), x, y);
}

/* ------------------------------------------------------------------ */
/* Paint                                                               */
/* ------------------------------------------------------------------ */

static SkBlendMode as_blend(int mode) {
    switch (mode) {
        case ZSK_BLEND_CLEAR: return SkBlendMode::kClear;
        case ZSK_BLEND_SRC: return SkBlendMode::kSrc;
        case ZSK_BLEND_DST: return SkBlendMode::kDst;
        case ZSK_BLEND_DST_OVER: return SkBlendMode::kDstOver;
        case ZSK_BLEND_SRC_IN: return SkBlendMode::kSrcIn;
        case ZSK_BLEND_DST_IN: return SkBlendMode::kDstIn;
        case ZSK_BLEND_SRC_OUT: return SkBlendMode::kSrcOut;
        case ZSK_BLEND_DST_OUT: return SkBlendMode::kDstOut;
        case ZSK_BLEND_SRC_ATOP: return SkBlendMode::kSrcATop;
        case ZSK_BLEND_DST_ATOP: return SkBlendMode::kDstATop;
        case ZSK_BLEND_XOR: return SkBlendMode::kXor;
        case ZSK_BLEND_PLUS: return SkBlendMode::kPlus;
        case ZSK_BLEND_MODULATE: return SkBlendMode::kModulate;
        case ZSK_BLEND_SCREEN: return SkBlendMode::kScreen;
        case ZSK_BLEND_MULTIPLY: return SkBlendMode::kMultiply;
        case ZSK_BLEND_DARKEN: return SkBlendMode::kDarken;
        case ZSK_BLEND_LIGHTEN: return SkBlendMode::kLighten;
        case ZSK_BLEND_SRC_OVER:
        default: return SkBlendMode::kSrcOver;
    }
}

ZSK_EXPORT zsk_paint* zsk_paint_create(void) {
    auto* p = new (std::nothrow) zsk_paint();
    if (p) p->paint.setAntiAlias(true);
    return p;
}
ZSK_EXPORT void zsk_paint_destroy(zsk_paint* p) { delete p; }
ZSK_EXPORT void zsk_paint_set_color(zsk_paint* p, uint32_t argb) { if (p) p->paint.setColor(argb); }
ZSK_EXPORT void zsk_paint_set_style(zsk_paint* p, int style) {
    if (!p) return;
    switch (style) {
        case ZSK_STROKE: p->paint.setStyle(SkPaint::kStroke_Style); break;
        case ZSK_FILL_AND_STROKE: p->paint.setStyle(SkPaint::kStroke_Style); break;
        case ZSK_FILL:
        default: p->paint.setStyle(SkPaint::kFill_Style); break;
    }
}
ZSK_EXPORT void zsk_paint_set_stroke_width(zsk_paint* p, float width) { if (p) p->paint.setStrokeWidth(width); }
ZSK_EXPORT void zsk_paint_set_aa(zsk_paint* p, int enabled) { if (p) p->paint.setAntiAlias(enabled != 0); }
ZSK_EXPORT void zsk_paint_set_blend_mode(zsk_paint* p, int mode) { if (p) p->paint.setBlendMode(as_blend(mode)); }
ZSK_EXPORT void zsk_paint_set_alpha(zsk_paint* p, int alpha) { if (p) p->paint.setAlpha((uint8_t)alpha); }

/* ------------------------------------------------------------------ */
/* Path                                                                */
/* ------------------------------------------------------------------ */

ZSK_EXPORT zsk_path* zsk_path_create(void) { return new (std::nothrow) zsk_path(); }
ZSK_EXPORT void zsk_path_destroy(zsk_path* p) { delete p; }
ZSK_EXPORT void zsk_path_move_to(zsk_path* p, float x, float y) { if (p) p->path.moveTo(x, y); }
ZSK_EXPORT void zsk_path_line_to(zsk_path* p, float x, float y) { if (p) p->path.lineTo(x, y); }
ZSK_EXPORT void zsk_path_quad_to(zsk_path* p, float x1, float y1, float x2, float y2) { if (p) p->path.quadTo(x1, y1, x2, y2); }
ZSK_EXPORT void zsk_path_cubic_to(zsk_path* p, float x1, float y1, float x2, float y2, float x3, float y3) {
    if (p) p->path.cubicTo(x1, y1, x2, y2, x3, y3);
}
ZSK_EXPORT void zsk_path_close(zsk_path* p) { if (p) p->path.close(); }
ZSK_EXPORT void zsk_path_add_rrect(zsk_path* p, float l, float t, float r, float b, float rx, float ry) {
    if (p) p->path.addRRect(SkRRect::MakeRectXY(SkRect::MakeLTRB(l, t, r, b), rx, ry));
}

/* ------------------------------------------------------------------ */
/* Images                                                              */
/* ------------------------------------------------------------------ */

ZSK_EXPORT zsk_image* zsk_image_make_from_encoded(const void* data, size_t len) {
    if (!data || len == 0) return nullptr;
    auto bytes = SkData::MakeWithCopy(data, len);
    auto img = SkImages::DeferredFromEncodedData(bytes);
    if (!img) return nullptr;
    auto* out = new (std::nothrow) zsk_image();
    if (!out) return nullptr;
    out->image = img;
    return out;
}

ZSK_EXPORT zsk_image* zsk_image_make_from_file(const char* path) {
    if (!path) return nullptr;
    auto data = SkData::MakeFromFileName(path);
    if (!data) return nullptr;
    auto img = SkImages::DeferredFromEncodedData(data);
    if (!img) return nullptr;
    auto* out = new (std::nothrow) zsk_image();
    if (!out) return nullptr;
    out->image = img;
    return out;
}

ZSK_EXPORT void zsk_image_destroy(zsk_image* img) { delete img; }
ZSK_EXPORT void zsk_image_size(const zsk_image* img, int* width, int* height) {
    if (width) *width = img && img->image ? img->image->width() : 0;
    if (height) *height = img && img->image ? img->image->height() : 0;
}

/* ------------------------------------------------------------------ */
/* Typography                                                          */
/* ------------------------------------------------------------------ */

ZSK_EXPORT zsk_fontcollection* zsk_fontcollection_create(void) {
    auto fc = sk_make_sp<skia::textlayout::FontCollection>();
    fc->setDefaultFontManager(SkFontMgr_New_DirectWrite());
    auto* out = new (std::nothrow) zsk_fontcollection();
    if (!out) return nullptr;
    out->fc = fc;
    return out;
}
ZSK_EXPORT void zsk_fontcollection_destroy(zsk_fontcollection* fc) { delete fc; }

static skia::textlayout::TextAlign as_text_align(int a) {
    switch (a) {
        case ZSK_ALIGN_RIGHT: return skia::textlayout::TextAlign::kRight;
        case ZSK_ALIGN_CENTER: return skia::textlayout::TextAlign::kCenter;
        case ZSK_ALIGN_JUSTIFY: return skia::textlayout::TextAlign::kJustify;
        case ZSK_ALIGN_START: return skia::textlayout::TextAlign::kStart;
        case ZSK_ALIGN_END: return skia::textlayout::TextAlign::kEnd;
        case ZSK_ALIGN_LEFT:
        default: return skia::textlayout::TextAlign::kLeft;
    }
}

static skia::textlayout::TextDirection as_text_direction(int d) {
    return d == ZSK_DIR_RTL ? skia::textlayout::TextDirection::kRtl
                            : skia::textlayout::TextDirection::kLtr;
}

ZSK_EXPORT zsk_paragraph_builder* zsk_paragraph_builder_create(zsk_fontcollection* fc,
                                                               const zsk_paragraph_style* style) {
    if (!fc) return nullptr;
    skia::textlayout::ParagraphStyle ps;
    if (style) {
        ps.setTextAlign(as_text_align(style->alignment));
        ps.setTextDirection(as_text_direction(style->direction));
        if (style->max_lines > 0) ps.setMaxLines(style->max_lines);
        if (style->ellipsis) ps.setEllipsis(std::u16string(u"\u2026"));
        if (style->height_multiplier > 0) ps.setHeight(style->height_multiplier);
    }
    auto builder = skia::textlayout::ParagraphBuilder::make(ps, fc->fc);
    auto* out = new (std::nothrow) zsk_paragraph_builder();
    if (!out) return nullptr;
    out->builder = std::move(builder);
    return out;
}

ZSK_EXPORT void zsk_paragraph_builder_destroy(zsk_paragraph_builder* b) { delete b; }

ZSK_EXPORT void zsk_paragraph_builder_push_style(zsk_paragraph_builder* b, const zsk_text_style* s) {
    if (!b || !s) return;
    skia::textlayout::TextStyle ts;
    if ((s->color & 0xFF000000) != 0 || s->color != 0) ts.setColor(s->color);
    if (s->font_size > 0) ts.setFontSize(s->font_size);
    if (s->height_multiplier > 0) ts.setHeight(s->height_multiplier);
    if (s->letter_spacing != 0) ts.setLetterSpacing(s->letter_spacing);
    if (s->weight >= 0) ts.setFontStyle(SkFontStyle(s->weight, SkFontStyle::kNormal_Width,
        s->slant == ZSK_SLANT_ITALIC ? SkFontStyle::kItalic_Slant : SkFontStyle::kUpright_Slant));
    else if (s->slant >= 0) {
        ts.setFontStyle(SkFontStyle(SkFontStyle::kNormal_Weight, SkFontStyle::kNormal_Width,
            s->slant == ZSK_SLANT_ITALIC ? SkFontStyle::kItalic_Slant : SkFontStyle::kUpright_Slant));
    }
    if (s->font_family && s->font_family[0]) {
        ts.setFontFamilies({SkString(s->font_family)});
    }
        if (s->decoration != ZSK_DECOR_NONE) {
        skia::textlayout::TextDecoration d = skia::textlayout::kNoDecoration;
        if (s->decoration & ZSK_DECOR_UNDERLINE) d = (skia::textlayout::TextDecoration)(d | skia::textlayout::kUnderline);
        if (s->decoration & ZSK_DECOR_OVERLINE) d = (skia::textlayout::TextDecoration)(d | skia::textlayout::kOverline);
        if (s->decoration & ZSK_DECOR_STRIKETHROUGH) d = (skia::textlayout::TextDecoration)(d | skia::textlayout::kLineThrough);
        ts.setDecoration(d);
        if (s->decoration_color != 0) ts.setDecorationColor(s->decoration_color);
    }
    b->builder->pushStyle(ts);
}

ZSK_EXPORT void zsk_paragraph_builder_pop(zsk_paragraph_builder* b) {
    if (b) b->builder->pop();
}

ZSK_EXPORT void zsk_paragraph_builder_add_text(zsk_paragraph_builder* b, const char* utf8, size_t len) {
    if (!b || !utf8 || len == 0) return;
    b->builder->addText(utf8, len);
}

ZSK_EXPORT zsk_paragraph* zsk_paragraph_builder_build(zsk_paragraph_builder* b) {
    if (!b) return nullptr;
    auto para = b->builder->Build();
    auto* res = new (std::nothrow) zsk_paragraph();
    if (!res) return nullptr;
    res->paragraph = std::move(para);
    return res;
}

ZSK_EXPORT void zsk_paragraph_destroy(zsk_paragraph* p) { delete p; }
ZSK_EXPORT void zsk_paragraph_layout(zsk_paragraph* p, float width) {
    if (p && p->paragraph) p->paragraph->layout(width);
}
ZSK_EXPORT float zsk_paragraph_width(zsk_paragraph* p) { return p && p->paragraph ? p->paragraph->getMaxWidth() : 0; }
ZSK_EXPORT float zsk_paragraph_height(zsk_paragraph* p) { return p && p->paragraph ? p->paragraph->getHeight() : 0; }
ZSK_EXPORT float zsk_paragraph_min_intrinsic_width(zsk_paragraph* p) {
    return p && p->paragraph ? p->paragraph->getMinIntrinsicWidth() : 0;
}
ZSK_EXPORT float zsk_paragraph_max_intrinsic_width(zsk_paragraph* p) {
    return p && p->paragraph ? p->paragraph->getMaxIntrinsicWidth() : 0;
}
ZSK_EXPORT float zsk_paragraph_alphabetic_baseline(zsk_paragraph* p) {
    return p && p->paragraph ? p->paragraph->getAlphabeticBaseline() : 0;
}
ZSK_EXPORT int zsk_paragraph_line_count(zsk_paragraph* p) {
    return p && p->paragraph ? (int)p->paragraph->lineNumber() : 0;
}

/* ------------------------------------------------------------------ */
/* Misc                                                                */
/* ------------------------------------------------------------------ */

