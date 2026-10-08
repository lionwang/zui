//! Small shared building blocks: avatars (colored rounded squares
//! with a white glyph), icon buttons and spacers.

const zui = @import("zui");
const ui = zui.widgets;
const element = zui.element;
const Context = zui.Context;
const Element = zui.Element;

const theme = @import("theme.zig");
const txt = theme.txt;
const icons = @import("icons.zig").icons;
const data = @import("data.zig");
const Session = data.Session;
const c = theme.c;

pub fn avatar(ctx: *Context, session: *const Session, size: f32) Element {
    const glyph = size * 0.6;
    return ui.rect(ctx, .{
        .style = .{
            .width = size,
            .height = size,
            .border_radius = size * 0.2,
            .background = session.color,
            .flex_shrink = 0,
            .align_items = .center,
            .justify_content = .center,
        },
        .children = &.{avatarGlyph(ctx, session, glyph)},
    });
}

pub fn avatarGlyph(ctx: *Context, session: *const Session, size: f32) Element {
    if (session.is_helper) {
        return ui.shape(ctx, .{
            .style = .{ .width = size, .height = size, .background = 0xFFFFFFFF },
            .ops = &icons.document,
        });
    }
    // Up to two characters of the name (the default-avatar look).
    const text = if (session.name.len <= 6) session.name else session.name[0..6];
    const fs: f32 = if (text.len > 4) 11 else 14;
    return ui.text(txt(fs, 0xFFFFFFFF), text);
}

pub fn iconButton(ctx: *Context, ops: []const element.PathOp, color: u32) Element {
    return ui.rect(ctx, .{
        .style = .{
            .width = 36,
            .height = 36,
            .flex_shrink = 0,
            .align_items = .center,
            .justify_content = .center,
            .border_radius = 4,
        },
        .cursor = .hand,
        .children = &.{
            ui.shape(ctx, .{
                .style = .{ .width = 20, .height = 20, .background = color },
                .ops = ops,
            }),
        },
    });
}

/// A stroked composer toolbar icon at its measured box size. The stroke
/// width is scaled with the box so every icon carries the same ~1.8px of
/// ink whatever its viewBox footprint.
pub fn toolIcon(
    ctx: *Context,
    w: f32,
    h: f32,
    ops: []const element.PathOp,
    color: u32,
    onclick: ?element.Handler,
) Element {
    return ui.rect(ctx, .{
        .style = .{
            .width = w,
            .height = h,
            .flex_shrink = 0,
            .align_items = .center,
            .justify_content = .center,
        },
        .cursor = if (onclick != null) .hand else .arrow,
        .onclick = onclick,
        .children = &.{ui.shape(ctx, .{
            .style = .{ .width = w, .height = h, .background = color },
            .ops = ops,
            .fill = false,
            // rendered stroke = stroke_width * box / 24 == 1.8px
            .stroke_width = 1.8 * 24 / @max(w, 1),
        })},
    });
}

/// The reply icon (13x18 in the reference): a stroked rounded bubble with
/// a 2x3 center tail. It is drawn as rects, not a path: no square viewBox
/// fits that aspect, and this keeps the stroke isotropic.
pub fn quoteIcon(ctx: *Context, color: u32, onclick: ?element.Handler) Element {
    return ui.rect(ctx, .{
        .style = .{ .flex_shrink = 0, .align_items = .center },
        .cursor = if (onclick != null) .hand else .arrow,
        .onclick = onclick,
        .children = &.{
            ui.rect(ctx, .{
                .style = .{
                    .width = 13,
                    .height = 14,
                    .flex_shrink = 0,
                    .border = .{ .top = 2, .left = 2, .right = 2, .bottom = 2 },
                    .border_color = color,
                    .border_radius = 6,
                },
            }),
            ui.rect(ctx, .{
                .style = .{ .width = 2, .height = 3, .flex_shrink = 0, .background = color },
            }),
        },
    });
}

/// A spacer that grows along the main axis (a flexible gap).
pub fn filler(ctx: *Context) Element {
    return ui.rect(ctx, .{ .style = .{ .flex_grow = 1 } });
}

// ----------------------------------------------------------------------
// Navigation rail
// ----------------------------------------------------------------------
