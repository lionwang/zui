//! Ergonomic Zig bindings over the zsk C ABI (Skia).
const std = @import("std");
const c = @cImport({
    @cInclude("zsk.h");
});

/// Initialize the MSVC dynamic-CRT state that Zig's entry point skips
/// (onexit table + C/C++ static initializers). Must be called once before
/// any Skia object is created.
pub fn initCrt() void {
    c.zsk_init_crt();
}

/// Encode a raw RGBA (0xAARRGGBB, row-major) buffer to a PNG file.
pub fn encodePng(rgba: []const u8, w: i32, h: i32, path: [:0]const u8) bool {
    return c.zsk_encode_png(rgba.ptr, w, h, path.ptr) != 0;
}pub const Context = struct {
    handle: *c.zsk_context,

    pub fn createGl() !Context {
        const h = c.zsk_context_create_gl() orelse return error.GpuContextFailed;
        return .{ .handle = h };
    }

    pub fn destroy(self: *Context) void {
        c.zsk_context_destroy(self.handle);
    }
};

pub const Surface = struct {
    handle: *c.zsk_surface,

    pub fn wrapGl(ctx: Context, width: i32, height: i32, samples: i32, stencil: i32, framebuffer: u32) !Surface {
        const h = c.zsk_surface_wrap_gl(ctx.handle, width, height, samples, stencil, framebuffer) orelse return error.SurfaceFailed;
        return .{ .handle = h };
    }

    pub fn destroy(self: *Surface) void {
        c.zsk_surface_destroy(self.handle);
    }

    pub fn canvas(self: *Surface) Canvas {
        return .{ .handle = c.zsk_surface_canvas(self.handle).? };
    }

    pub fn flushAndSubmit(self: *Surface) void {
        c.zsk_surface_flush_and_submit(self.handle);
    }
    /// Copy the surface pixels into an RGBA buffer (w*h*4 bytes).
    pub fn readPixels(self: *Surface, rgba: []u8, w: i32, h: i32) bool {
        return c.zsk_surface_read_pixels(self.handle, rgba.ptr, w, h) != 0;
    }
};

pub const Canvas = struct {
    handle: *c.zsk_canvas,

    pub fn save(self: Canvas) void {
        c.zsk_canvas_save(self.handle);
    }
    pub fn restore(self: Canvas) void {
        c.zsk_canvas_restore(self.handle);
    }
    pub fn saveCount(self: Canvas) i32 {
        return c.zsk_canvas_save_count(self.handle);
    }
    pub fn restoreToCount(self: Canvas, count: i32) void {
        c.zsk_canvas_restore_to_count(self.handle, count);
    }
    pub fn translate(self: Canvas, x: f32, y: f32) void {
        c.zsk_canvas_translate(self.handle, x, y);
    }
    pub fn scale(self: Canvas, x: f32, y: f32) void {
        c.zsk_canvas_scale(self.handle, x, y);
    }
    pub fn clipRect(self: Canvas, rect: Rect, aa: bool) void {
        c.zsk_canvas_clip_rect(self.handle, rect.left, rect.top, rect.right, rect.bottom, if (aa) 1 else 0);
    }
    pub fn clipRRect(self: Canvas, rect: Rect, rx: f32, ry: f32, aa: bool) void {
        c.zsk_canvas_clip_rrect(self.handle, rect.left, rect.top, rect.right, rect.bottom, rx, ry, if (aa) 1 else 0);
    }
    pub fn clear(self: Canvas, color: u32) void {
        c.zsk_canvas_clear(self.handle, color);
    }
    pub fn drawRect(self: Canvas, rect: Rect, paint: Paint) void {
        c.zsk_canvas_draw_rect(self.handle, rect.left, rect.top, rect.right, rect.bottom, paint.handle);
    }
    pub fn drawRRect(self: Canvas, rect: Rect, rx: f32, ry: f32, paint: Paint) void {
        c.zsk_canvas_draw_rrect(self.handle, rect.left, rect.top, rect.right, rect.bottom, rx, ry, paint.handle);
    }
    pub fn drawPath(self: Canvas, path: Path, paint: Paint) void {
        c.zsk_canvas_draw_path(self.handle, path.handle, paint.handle);
    }
    pub fn drawImage(self: Canvas, image: Image, x: f32, y: f32, paint: ?Paint) void {
        c.zsk_canvas_draw_image(self.handle, image.handle, x, y, if (paint) |p| p.handle else null);
    }
    pub fn drawParagraph(self: Canvas, para: Paragraph, x: f32, y: f32) void {
        c.zsk_canvas_draw_paragraph(self.handle, para.handle, x, y);
    }
};

pub const Paint = struct {
    handle: *c.zsk_paint,

    pub fn create() !Paint {
        const h = c.zsk_paint_create() orelse return error.OutOfMemory;
        return .{ .handle = h };
    }
    pub fn destroy(self: *Paint) void {
        c.zsk_paint_destroy(self.handle);
    }
    pub fn setColor(self: *Paint, color: u32) void {
        c.zsk_paint_set_color(self.handle, color);
    }
    pub fn setStyle(self: *Paint, style: PaintStyle) void {
        c.zsk_paint_set_style(self.handle, @intFromEnum(style));
    }
    pub fn setStrokeWidth(self: *Paint, width: f32) void {
        c.zsk_paint_set_stroke_width(self.handle, width);
    }
    pub fn setAntiAlias(self: *Paint, enabled: bool) void {
        c.zsk_paint_set_aa(self.handle, if (enabled) 1 else 0);
    }
    pub fn setBlendMode(self: *Paint, mode: BlendMode) void {
        c.zsk_paint_set_blend_mode(self.handle, @intFromEnum(mode));
    }
    pub fn setAlpha(self: *Paint, alpha: u8) void {
        c.zsk_paint_set_alpha(self.handle, alpha);
    }
};

pub const PaintStyle = enum(c_int) {
    fill = c.ZSK_FILL,
    stroke = c.ZSK_STROKE,
    fill_and_stroke = c.ZSK_FILL_AND_STROKE,
};

pub const BlendMode = enum(c_int) {
    clear = c.ZSK_BLEND_CLEAR,
    src = c.ZSK_BLEND_SRC,
    dst = c.ZSK_BLEND_DST,
    src_over = c.ZSK_BLEND_SRC_OVER,
    dst_over = c.ZSK_BLEND_DST_OVER,
    src_in = c.ZSK_BLEND_SRC_IN,
    dst_in = c.ZSK_BLEND_DST_IN,
    src_out = c.ZSK_BLEND_SRC_OUT,
    dst_out = c.ZSK_BLEND_DST_OUT,
    src_atop = c.ZSK_BLEND_SRC_ATOP,
    dst_atop = c.ZSK_BLEND_DST_ATOP,
    xor = c.ZSK_BLEND_XOR,
    plus = c.ZSK_BLEND_PLUS,
    modulate = c.ZSK_BLEND_MODULATE,
    screen = c.ZSK_BLEND_SCREEN,
    multiply = c.ZSK_BLEND_MULTIPLY,
    darken = c.ZSK_BLEND_DARKEN,
    lighten = c.ZSK_BLEND_LIGHTEN,
};

pub const Path = struct {
    handle: *c.zsk_path,

    pub fn create() !Path {
        const h = c.zsk_path_create() orelse return error.OutOfMemory;
        return .{ .handle = h };
    }
    pub fn destroy(self: *Path) void {
        c.zsk_path_destroy(self.handle);
    }
    pub fn moveTo(self: *Path, x: f32, y: f32) void {
        c.zsk_path_move_to(self.handle, x, y);
    }
    pub fn lineTo(self: *Path, x: f32, y: f32) void {
        c.zsk_path_line_to(self.handle, x, y);
    }
    pub fn quadTo(self: *Path, x1: f32, y1: f32, x2: f32, y2: f32) void {
        c.zsk_path_quad_to(self.handle, x1, y1, x2, y2);
    }
    pub fn cubicTo(self: *Path, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) void {
        c.zsk_path_cubic_to(self.handle, x1, y1, x2, y2, x3, y3);
    }
    pub fn close(self: *Path) void {
        c.zsk_path_close(self.handle);
    }
    pub fn addRRect(self: *Path, rect: Rect, rx: f32, ry: f32) void {
        c.zsk_path_add_rrect(self.handle, rect.left, rect.top, rect.right, rect.bottom, rx, ry);
    }
};

pub const Image = struct {
    handle: *c.zsk_image,

    pub fn fromEncoded(data: []const u8) !Image {
        const h = c.zsk_image_make_from_encoded(data.ptr, data.len) orelse return error.ImageDecodeFailed;
        return .{ .handle = h };
    }
    pub fn fromFile(path: [:0]const u8) !Image {
        const h = c.zsk_image_make_from_file(path.ptr) orelse return error.ImageLoadFailed;
        return .{ .handle = h };
    }
    pub fn destroy(self: *Image) void {
        c.zsk_image_destroy(self.handle);
    }
    pub fn size(self: Image) Size {
        var w: i32 = 0;
        var h: i32 = 0;
        c.zsk_image_size(self.handle, &w, &h);
        return .{ .width = w, .height = h };
    }
};

pub const FontCollection = struct {
    handle: *c.zsk_fontcollection,

    pub fn create() !FontCollection {
        const h = c.zsk_fontcollection_create() orelse return error.FontCollectionFailed;
        return .{ .handle = h };
    }
    pub fn destroy(self: *FontCollection) void {
        c.zsk_fontcollection_destroy(self.handle);
    }
};

pub const TextAlign = enum(c_int) {
    left = c.ZSK_ALIGN_LEFT,
    right = c.ZSK_ALIGN_RIGHT,
    center = c.ZSK_ALIGN_CENTER,
    justify = c.ZSK_ALIGN_JUSTIFY,
    start = c.ZSK_ALIGN_START,
    end = c.ZSK_ALIGN_END,
};

pub const TextDirection = enum(c_int) {
    ltr = c.ZSK_DIR_LTR,
    rtl = c.ZSK_DIR_RTL,
};

pub const FontWeight = enum(c_int) {
    thin = c.ZSK_WEIGHT_THIN,
    extralight = c.ZSK_WEIGHT_EXTRALIGHT,
    light = c.ZSK_WEIGHT_LIGHT,
    normal = c.ZSK_WEIGHT_NORMAL,
    medium = c.ZSK_WEIGHT_MEDIUM,
    semibold = c.ZSK_WEIGHT_SEMIBOLD,
    bold = c.ZSK_WEIGHT_BOLD,
    extrabold = c.ZSK_WEIGHT_EXTRABOLD,
    black = c.ZSK_WEIGHT_BLACK,
};

pub const FontSlant = enum(c_int) {
    upright = c.ZSK_SLANT_UPRIGHT,
    italic = c.ZSK_SLANT_ITALIC,
};

pub const Decoration = packed struct {
    underline: bool = false,
    overline: bool = false,
    strikethrough: bool = false,
};

pub const TextStyle = struct {
    color: u32 = 0xFF000000,
    font_size: f32 = 16,
    height_multiplier: f32 = 1.4,
    letter_spacing: f32 = 0,
    weight: FontWeight = .normal,
    slant: FontSlant = .upright,
    font_family: ?[]const u8 = null,
    decoration: Decoration = .{},
    decoration_color: u32 = 0,

    pub fn toC(self: TextStyle, arena: std.mem.Allocator) !c.zsk_text_style {
        var s: c.zsk_text_style = std.mem.zeroes(c.zsk_text_style);
        s.color = self.color;
        s.font_size = self.font_size;
        s.height_multiplier = self.height_multiplier;
        s.letter_spacing = self.letter_spacing;
        s.weight = @intFromEnum(self.weight);
        s.slant = @intFromEnum(self.slant);
        s.decoration = @as(c_int, if (self.decoration.underline) c.ZSK_DECOR_UNDERLINE else 0) |
            @as(c_int, if (self.decoration.overline) c.ZSK_DECOR_OVERLINE else 0) |
            @as(c_int, if (self.decoration.strikethrough) c.ZSK_DECOR_STRIKETHROUGH else 0);
        s.decoration_color = self.decoration_color;
        if (self.font_family) |fam| {
            const z = try arena.allocSentinel(u8, fam.len, 0);
            @memcpy(z[0..fam.len], fam);
            s.font_family = z.ptr;
        }
        return s;
    }
};

pub const ParagraphStyle = struct {
    direction: TextDirection = .ltr,
    alignment: TextAlign = .left,
    max_lines: i32 = 0,
    ellipsis: bool = false,
    height_multiplier: f32 = 0,

    pub fn toC(self: ParagraphStyle) c.zsk_paragraph_style {
        var s: c.zsk_paragraph_style = std.mem.zeroes(c.zsk_paragraph_style);
        s.direction = @intFromEnum(self.direction);
        s.alignment = @intFromEnum(self.alignment);
        s.max_lines = self.max_lines;
        s.ellipsis = if (self.ellipsis) 1 else 0;
        s.height_multiplier = self.height_multiplier;
        return s;
    }
};

pub const ParagraphBuilder = struct {
    handle: *c.zsk_paragraph_builder,

    pub fn create(fc: FontCollection, style: ParagraphStyle) !ParagraphBuilder {
        const ps = style.toC();
        const h = c.zsk_paragraph_builder_create(fc.handle, &ps) orelse return error.OutOfMemory;
        return .{ .handle = h };
    }
    pub fn destroy(self: *ParagraphBuilder) void {
        c.zsk_paragraph_builder_destroy(self.handle);
    }
    pub fn pushStyle(self: *ParagraphBuilder, style: TextStyle, arena: std.mem.Allocator) !void {
        const s = try style.toC(arena);
        c.zsk_paragraph_builder_push_style(self.handle, &s);
    }
    pub fn pop(self: *ParagraphBuilder) void {
        c.zsk_paragraph_builder_pop(self.handle);
    }
    pub fn addText(self: *ParagraphBuilder, text: []const u8) void {
        c.zsk_paragraph_builder_add_text(self.handle, text.ptr, text.len);
    }
    pub fn build(self: *ParagraphBuilder) !Paragraph {
        const h = c.zsk_paragraph_builder_build(self.handle) orelse return error.OutOfMemory;
        return .{ .handle = h };
    }
};

pub const Paragraph = struct {
    handle: *c.zsk_paragraph,

    pub fn destroy(self: *Paragraph) void {
        c.zsk_paragraph_destroy(self.handle);
    }
    pub fn layout(self: *Paragraph, available_width: f32) void {
        c.zsk_paragraph_layout(self.handle, available_width);
    }
    pub fn width(self: Paragraph) f32 {
        return c.zsk_paragraph_width(self.handle);
    }
    pub fn height(self: Paragraph) f32 {
        return c.zsk_paragraph_height(self.handle);
    }
    pub fn minIntrinsicWidth(self: Paragraph) f32 {
        return c.zsk_paragraph_min_intrinsic_width(self.handle);
    }
    pub fn maxIntrinsicWidth(self: Paragraph) f32 {
        return c.zsk_paragraph_max_intrinsic_width(self.handle);
    }
    pub fn alphabeticBaseline(self: Paragraph) f32 {
        return c.zsk_paragraph_alphabetic_baseline(self.handle);
    }
    pub fn lineCount(self: Paragraph) i32 {
        return c.zsk_paragraph_line_count(self.handle);
    }
};

pub const Size = struct { width: i32 = 0, height: i32 = 0 };

pub const Rect = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn fromSize(w: f32, h: f32) Rect {
        return .{ .right = w, .bottom = h };
    }
    pub fn width(self: Rect) f32 {
        return self.right - self.left;
    }
    pub fn height(self: Rect) f32 {
        return self.bottom - self.top;
    }
};

/// ARGB color helper: 0xAARRGGBB.
pub fn argb(alpha: u8, red: u8, green: u8, blue: u8) u32 {
    return (@as(u32, alpha) << 24) | (@as(u32, red) << 16) | (@as(u32, green) << 8) | blue;
}
pub const rgb = struct {
    pub fn black() u32 { return 0xFF000000; }
    pub fn white() u32 { return 0xFFFFFFFF; }
    pub fn red() u32 { return 0xFFFF0000; }
    pub fn green() u32 { return 0xFF00AA00; }
    pub fn blue() u32 { return 0xFF3366CC; }
    pub fn gray() u32 { return 0xFF888888; }
};
