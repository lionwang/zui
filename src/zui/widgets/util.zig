//! Shared helpers for the widget modules.
//!
//! `applyUser`: because most `Style` fields have no "unset" value (a
//! background of 0 is a real color: transparent), the widget convention is
//! "0 / null means unset, explicit values win". This spells that rule out
//! for the fields widgets actually honor.
//!
//! `hostBox`: geometry an event handler or a dynamic child needs (a track to
//! map a drag onto, a width for a percentage fill) is only knowable after
//! the previous reconciliation, so widgets read it through their component
//! node's expansion at the time they need it.

const std = @import("std");
const element = @import("../element.zig");
const node_mod = @import("../node.zig");
const skia = @import("../skia.zig");

/// Deep-copy an element tree into `arena`.
///
/// Element trees built in a render function live *partly on that function's
/// stack: the `&.{ ... }` child literals dangle once the render returns,
/// while the tree is only read later, during reconciliation. Widgets whose
/// props carry elements (tabs, popovers, dialogs, accordions) or whose
/// children come from higher up therefore deep-copy before boxing anything
/// that survives the current render function.
pub fn dupElement(arena: std.mem.Allocator, el: element.Element) error{OutOfMemory}!element.Element {
    return switch (el) {
        .rect => |r| .{ .rect = .{
            .key = r.key,
            .style = r.style,
            .children = try dupElements(arena, r.children),
            .onclick = r.onclick,
            .onmouseenter = r.onmouseenter,
            .onmouseleave = r.onmouseleave,
            .cursor = r.cursor,
            .focusable = r.focusable,
            .autofocus = r.autofocus,
            .onchar = r.onchar,
            .onkey = r.onkey,
            .onmouse = r.onmouse,
        } },
        // A component element's props are already boxed in the arena (by
        // `componentProps`), so nothing under it can dangle.
        .component => el,
        .text => el,
        .image => el,
        .shape => el,
        .none => el,
    };
}

pub fn dupElements(arena: std.mem.Allocator, els: []const element.Element) error{OutOfMemory}![]const element.Element {
    if (els.len == 0) return &.{};
    const copied = try arena.alloc(element.Element, els.len);
    for (els, 0..) |e, i| copied[i] = try dupElement(arena, e);
    return copied;
}

pub fn applyUser(style: *element.Style, user: element.Style) void {
    if (user.background != 0) style.background = user.background;
    if (user.border_color != 0) style.border_color = user.border_color;
    if (user.border.horizontal() != 0 or user.border.vertical() != 0) style.border = user.border;
    if (user.border_radius != 0) style.border_radius = user.border_radius;
    if (user.width != null) style.width = user.width;
    if (user.height != null) style.height = user.height;
    if (user.min_width != null) style.min_width = user.min_width;
    if (user.min_height != null) style.min_height = user.min_height;
    if (user.max_width != null) style.max_width = user.max_width;
    if (user.max_height != null) style.max_height = user.max_height;
    if (user.padding.horizontal() != 0 or user.padding.vertical() != 0) style.padding = user.padding;
    if (user.margin.horizontal() != 0 or user.margin.vertical() != 0) style.margin = user.margin;
    if (user.flex_grow != 0) style.flex_grow = user.flex_grow;
    if (user.flex_shrink != 1) style.flex_shrink = user.flex_shrink;
    if (user.gap != 0) style.gap = user.gap;
    if (user.color != 0xFF000000) style.color = user.color;
    if (user.font_size != 16) style.font_size = user.font_size;
    if (user.font_weight != null) style.font_weight = user.font_weight;
}
