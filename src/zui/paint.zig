//! Renders the laid-out node tree with Skia.
//!
//! Painting walks the retained tree (whose `layout` fields were filled by
//! `layout.layout`) and issues draw calls: rounded rectangles for backgrounds,
//! per-edge rectangles for borders, cached paragraphs for text and cached
//! images. Clips are pushed for `overflow: hidden` containers.

const std = @import("std");
const node = @import("node.zig");
const element = @import("element.zig");
const skia = @import("skia.zig");

pub const PaintContext = struct {
    canvas: skia.Canvas,
    font_collection: skia.FontCollection,
    arena: std.mem.Allocator,
    fill: skia.Paint,
    stroke: skia.Paint,
};

/// Paint a node and (for containers) its children.
pub fn paint(ctx: *PaintContext, n: *node.Node) !void {
    switch (n.kind) {
        .component => {
            // A component node is transparent: it forwards to its expansion.
            if (n.child) |c| try paint(ctx, c);
        },
        .rect => {
            const b = n.bounds();
            const s = n.style;

            if (s.background != 0) {
                ctx.fill.setColor(s.background);
                ctx.fill.setStyle(.fill);
                if (s.border_radius > 0) {
                    ctx.canvas.drawRRect(b, s.border_radius, s.border_radius, ctx.fill);
                } else {
                    ctx.canvas.drawRect(b, ctx.fill);
                }
            }

            paintBorder(ctx, n, b);

            // Scroll containers always clip (the content is offset by layout).
            const clip = (s.overflow == .hidden or s.scroll != null) and n.children.items.len > 0;
            if (clip) {
                ctx.canvas.save();
                if (s.border_radius > 0) {
                    ctx.canvas.clipRRect(b, s.border_radius, s.border_radius, true);
                } else {
                    ctx.canvas.clipRect(b, true);
                }
            }
            for (n.children.items) |c| try paint(ctx, c);
            if (clip) {
                ctx.canvas.restore();
                // Only vertical (column) scroll containers paint a thumb.
                if (s.direction == .column) paintScrollbar(ctx, n);
            }
        },
        .text => {
            if (n.text == null) return;
            const para = try n.paragraphFor(ctx.font_collection, ctx.arena);
            if (n.style.selection) |sel| paintSelection(ctx, para, n, sel);
            ctx.canvas.drawParagraph(para, n.layout.x, n.layout.y);
        },
        .image => {
            try paintImage(ctx, n);
        },
        .shape => {
            try paintShape(ctx, n);
        },
    }
}

/// Draw a shape: the cached path is authored in a `view x view` coordinate
/// space and scaled onto the element box, so icon data is resolution
/// independent.
fn paintShape(ctx: *PaintContext, n: *node.Node) !void {
    if (n.style.background == 0) return;
    const path = n.pathFor() catch return;
    const b = n.bounds();
    const view = if (n.shape_view > 0) n.shape_view else 1;
    const sx = b.width() / view;
    const sy = b.height() / view;
    if (sx <= 0 or sy <= 0) return;

    ctx.canvas.save();
    defer ctx.canvas.restore();
    ctx.canvas.translate(b.left, b.top);
    ctx.canvas.scale(sx, sy);
    const color = n.style.background;
    if (n.shape_fill) {
        ctx.fill.setColor(color);
        ctx.fill.setStyle(.fill);
        ctx.canvas.drawPath(path, ctx.fill);
    } else {
        ctx.stroke.setColor(color);
        ctx.stroke.setStyle(.stroke);
        ctx.stroke.setStrokeWidth(n.shape_stroke_width);
        ctx.canvas.drawPath(path, ctx.stroke);
    }
}

/// The thin thumb on the right edge of a scroll container, shown only when
/// the content actually overflows (visibility proportional to the offset).
fn paintScrollbar(ctx: *PaintContext, n: *node.Node) void {
    const st = n.scroll orelse return;
    const max = st.maxOffset();
    if (max <= 0) return;
    const b = n.bounds();
    const fraction = b.height() / st.content_h;
    const thumb_h = @max(b.height() * fraction, 24);
    const track_h = b.height() - thumb_h;
    const thumb_y = b.top + track_h * (st.offset / max);
    const w: f32 = 5;
    ctx.fill.setColor(0x66000000);
    ctx.fill.setStyle(.fill);
    ctx.canvas.drawRRect(.{
        .left = b.right - w - 2,
        .top = thumb_y,
        .right = b.right - 2,
        .bottom = thumb_y + thumb_h,
    }, w / 2, w / 2, ctx.fill);
}

/// The selection highlight over (part of) a text node's glyphs.
fn paintSelection(ctx: *PaintContext, para: skia.Paragraph, n: *node.Node, sel: element.Selection) void {
    if (sel.start == sel.end) return;
    var boxes: [16]f32 = undefined;
    const count = para.rectsForRange(sel.start, sel.end, &boxes);
    if (count == 0) return;
    ctx.fill.setColor(n.style.selection_color);
    ctx.fill.setStyle(.fill);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const b = boxes[i * 4 ..][0..4];
        ctx.canvas.drawRect(.{
            .left = n.layout.x + b[0],
            .top = n.layout.y + b[1],
            .right = n.layout.x + b[2],
            .bottom = n.layout.y + b[3],
        }, ctx.fill);
    }
}

fn paintBorder(ctx: *PaintContext, n: *node.Node, b: skia.Rect) void {
    const s = n.style;
    const total = s.border.left + s.border.top + s.border.right + s.border.bottom;
    if (total == 0 or s.border_color == 0) return;

    ctx.fill.setColor(s.border_color);
    ctx.fill.setStyle(.fill);

    if (s.border_radius > 0) {
        // Rounded border: approximate with a stroke of the average width.
        const avg = total / 4;
        ctx.stroke.setColor(s.border_color);
        ctx.stroke.setStyle(.stroke);
        ctx.stroke.setStrokeWidth(avg);
        const inset = avg / 2;
        ctx.canvas.drawRRect(.{
            .left = b.left + inset,
            .top = b.top + inset,
            .right = b.right - inset,
            .bottom = b.bottom - inset,
        }, s.border_radius, s.border_radius, ctx.stroke);
        return;
    }

    if (s.border.top > 0) {
        ctx.canvas.drawRect(.{
            .left = b.left,
            .top = b.top,
            .right = b.right,
            .bottom = b.top + s.border.top,
        }, ctx.fill);
    }
    if (s.border.bottom > 0) {
        ctx.canvas.drawRect(.{
            .left = b.left,
            .top = b.bottom - s.border.bottom,
            .right = b.right,
            .bottom = b.bottom,
        }, ctx.fill);
    }
    if (s.border.left > 0) {
        ctx.canvas.drawRect(.{
            .left = b.left,
            .top = b.top,
            .right = b.left + s.border.left,
            .bottom = b.bottom,
        }, ctx.fill);
    }
    if (s.border.right > 0) {
        ctx.canvas.drawRect(.{
            .left = b.right - s.border.right,
            .top = b.top,
            .right = b.right,
            .bottom = b.bottom,
        }, ctx.fill);
    }
}

fn paintImage(ctx: *PaintContext, n: *node.Node) !void {
    if (n.image_sig == 0) return;
    const im = n.imageFor() catch return;
    const sz = im.size();
    const iw: f32 = @floatFromInt(sz.width);
    const ih: f32 = @floatFromInt(sz.height);
    if (iw == 0 or ih == 0) return;

    const b = n.bounds();
    var dest = b;
    switch (n.image_fit) {
        .fill => {},
        .none => {
            dest.right = b.left + iw;
            dest.bottom = b.top + ih;
        },
        .contain, .cover => {
            const scale_x = b.width() / iw;
            const scale_y = b.height() / ih;
            const scale = if (n.image_fit == .contain) @min(scale_x, scale_y) else @max(scale_x, scale_y);
            const dw = iw * scale;
            const dh = ih * scale;
            dest.left = b.left + (b.width() - dw) / 2;
            dest.top = b.top + (b.height() - dh) / 2;
            dest.right = dest.left + dw;
            dest.bottom = dest.top + dh;
        },
    }

    // Skia draws the image at its natural size from the top-left corner, so
    // we scale the canvas to map the image onto the destination rect.
    ctx.canvas.save();
    ctx.canvas.translate(dest.left, dest.top);
    ctx.canvas.scale(dest.width() / iw, dest.height() / ih);
    ctx.canvas.drawImage(im, 0, 0, null);
    ctx.canvas.restore();
}

/// The image bytes for the current frame are stored on the app; the node caches
/// the decoded image so we only need the bytes on cache misses.
fn currentImageBytes(n: *node.Node) []const u8 {
    // Image data is only needed when (re)decoding; the node caches the result.
    return n.image_data orelse &.{};
}
