//! Renders the laid-out node tree with Skia.
//!
//! Painting walks the retained tree (whose `layout` fields were filled by
//! `layout.layout`) and issues draw calls: rounded rectangles for backgrounds,
//! per-edge rectangles for borders, cached paragraphs for text and cached
//! images. Clips are pushed for `overflow: hidden` containers.

const std = @import("std");
const node = @import("node.zig");
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

            const clip = s.overflow == .hidden and n.children.items.len > 0;
            if (clip) {
                ctx.canvas.save();
                if (s.border_radius > 0) {
                    ctx.canvas.clipRRect(b, s.border_radius, s.border_radius, true);
                } else {
                    ctx.canvas.clipRect(b, true);
                }
            }
            for (n.children.items) |c| try paint(ctx, c);
            if (clip) ctx.canvas.restore();
        },
        .text => {
            if (n.text == null) return;
            const para = try n.paragraphFor(ctx.font_collection, ctx.arena);
            ctx.canvas.drawParagraph(para, n.layout.x, n.layout.y);
        },
        .image => {
            try paintImage(ctx, n);
        },
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