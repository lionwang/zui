//! Built-in elements with an ergonomic, Freya-flavored API.
//!
//! Container widgets (`rect`, `column`, `row`, `spacer`, `button`) take the
//! render `Context` because they copy their child list into the per-frame
//! arena: a `&.{ ... }` literal lives on the render function stack and would
//! dangle once that function returns, and the returned element tree is read
//! later, during reconciliation. Leaves such as `text` hold no children and
//! keep the simpler signature.
//!
//! ```zig
//! const zui = @import("zui");
//! const ui = zui.ui;
//!
//! fn counter(ctx: *zui.Context) zui.Element {
//!     var count = ctx.useState(i32, 0);
//!     return ui.column(ctx, .{
//!         .style = .{ .padding = .all(20), .gap = 12 },
//!         .children = &.{
//!             ui.text(.{ .color = 0xFFFFFFFF, .font_size = 24 }, "Count"),
//!             ui.button(ctx, .{ .label = "+1", .onclick = count.handler(...) }),
//!         },
//!     });
//! }
//! ```

const std = @import("std");
const element = @import("../element.zig");
const context = @import("../context.zig");

/// Copy a child list into the per-frame arena so that it stays valid after
/// the render function has returned. Empty lists are shared.
fn adoptChildren(ctx: *context.Context, children: []const element.Element) []const element.Element {
    if (children.len == 0) return &.{};
    return ctx.arena.dupe(element.Element, children) catch
        @panic("zui: out of memory while building the element tree");
}

/// Arguments for the `rect` / `column` / `row` widgets.
pub const RectArgs = struct {
    style: element.Style = .{},
    children: []const element.Element = &.{},
    onclick: ?element.Handler = null,
    onmouseenter: ?element.Handler = null,
    onmouseleave: ?element.Handler = null,
    key: ?[]const u8 = null,
    cursor: ?element.Cursor = null,
};

/// A plain container; layout comes entirely from `style`.
pub fn rect(ctx: *context.Context, args: RectArgs) element.Element {
    return .{ .rect = .{
        .key = args.key,
        .style = args.style,
        .children = adoptChildren(ctx, args.children),
        .onclick = args.onclick,
        .onmouseenter = args.onmouseenter,
        .onmouseleave = args.onmouseleave,
        .cursor = args.cursor,
    } };
}

/// A flex column (the default direction in Freya).
pub fn column(ctx: *context.Context, args: RectArgs) element.Element {
    var style = args.style;
    style.direction = .column;
    return rect(ctx, .{
        .style = style,
        .children = args.children,
        .onclick = args.onclick,
        .onmouseenter = args.onmouseenter,
        .onmouseleave = args.onmouseleave,
        .key = args.key,
        .cursor = args.cursor,
    });
}

/// A flex row.
pub fn row(ctx: *context.Context, args: RectArgs) element.Element {
    var style = args.style;
    style.direction = .row;
    return rect(ctx, .{
        .style = style,
        .children = args.children,
        .onclick = args.onclick,
        .onmouseenter = args.onmouseenter,
        .onmouseleave = args.onmouseleave,
        .key = args.key,
        .cursor = args.cursor,
    });
}

/// A container that grows to fill the available space along the main axis.
pub fn spacer(ctx: *context.Context, args: RectArgs) element.Element {
    var style = args.style;
    style.flex_grow = if (style.flex_grow == 0) 1 else style.flex_grow;
    return rect(ctx, .{
        .style = style,
        .children = args.children,
        .onclick = args.onclick,
        .onmouseenter = args.onmouseenter,
        .onmouseleave = args.onmouseleave,
        .key = args.key,
        .cursor = args.cursor,
    });
}

/// A text run. Text-specific style fields (`color`, `font_size`, ...) live on
/// `Style` so they can be shared with every element kind.
pub fn text(style: element.Style, content: []const u8) element.Element {
    return .{ .text = .{ .style = style, .content = content } };
}

/// Like `text`, but formats the content into the per-frame arena.
pub fn textFmt(arena: std.mem.Allocator, style: element.Style, comptime fmt: []const u8, fmt_args: anytype) !element.Element {
    const content = try std.fmt.allocPrint(arena, fmt, fmt_args);
    return text(style, content);
}

pub const ImageArgs = struct {
    style: element.Style = .{},
    /// Encoded image bytes (PNG / JPEG / WebP / ...).
    data: []const u8 = &.{},
    /// Alternatively, a path that is loaded once and cached.
    path: ?[:0]const u8 = null,
    fit: element.Fit = .contain,
    key: ?[]const u8 = null,
};

/// A raster image.
pub fn image(args: ImageArgs) element.Element {
    return .{ .image = .{
        .style = args.style,
        .data = args.data,
        .path = args.path,
        .fit = args.fit,
    } };
}

pub const ButtonArgs = struct {
    style: element.Style = .{},
    label: []const u8 = "",
    onclick: ?element.Handler = null,
    key: ?[]const u8 = null,
    cursor: ?element.Cursor = .hand,
};

/// A simple button: a padded, rounded rect with a centered label.
pub fn button(ctx: *context.Context, args: ButtonArgs) element.Element {
    var style = args.style;
    if (style.background == 0) style.background = 0xFF4488CC;
    if (style.border_radius == 0) style.border_radius = 8;
    if (style.padding.horizontal() == 0) style.padding = .all(10);
    return rect(ctx, .{
        .style = style,
        .onclick = args.onclick,
        .cursor = args.cursor,
        .key = args.key,
        .children = &.{
            .{ .text = .{
                .style = .{ .color = 0xFFFFFFFF, .font_size = 16 },
                .content = args.label,
            } },
        },
    });
}