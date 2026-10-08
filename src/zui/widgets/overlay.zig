//! Floating layers: tooltips, popovers, dropdown menus, modal dialogs and
//! notification toasts.
//!
//! Every layer renders as an absolutely positioned child of its host rect,
//! so a host (the popover wrapper, the dialog root) must be one of the
//! *last* children of its parent: paint order and hit testing visit a
//! rect's children in source order, so a layer placed last draws above and
//! receives events before everything painted before it.
//!
//! ```zig
//! return ui.column(ctx, .{
//!     .children = util.dupElements(ctx.arena, &.{ //!         ui.button(ctx, .{ .label = "Menu", .onclick = open.handler(toggle) }),
//!         ui.dropdown(ctx, .{ .open = open, .selected = choice, .items = items }),
//! }) catch @panic("zui: out of memory while building the element tree"),
//! });
//! ```

const std = @import("std");
const element = @import("../element.zig");
const context = @import("../context.zig");
const node_mod = @import("../node.zig");
const events = @import("../events.zig");
const skia = @import("../skia.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const button_mod = @import("button.zig");
const util = @import("util.zig");

/// Which side of its anchor a layer opens on.
pub const Side = enum {
    top,
    bottom,
    left,
    right,
};

fn hostBox(host: ?*node_mod.Node) ?skia.Rect {
    const comp = host orelse return null;
    const child = comp.child orelse return null;
    return child.bounds();
}

/// Box of the `i`-th child of the component's rendered root (previous
/// frame), if that child exists yet.
fn childBox(host: ?*node_mod.Node, i: usize) ?skia.Rect {
    const comp = host orelse return null;
    const root = comp.child orelse return null;
    if (root.children.items.len <= i) return null;
    return root.children.items[i].bounds();
}

/// Absolute placement of a layer box next to its anchor (both in absolute
/// coordinates; the caller subtracts the host origin).
fn placeLayer(anchor: skia.Rect, layer: skia.Rect, side: Side, gap: f32) struct { x: f32, y: f32 } {
    var x: f32 = anchor.left + (anchor.width() - layer.width()) / 2;
    var y: f32 = anchor.bottom + gap;
    switch (side) {
        .top => y = anchor.top - layer.height() - gap,
        .right => {
            x = anchor.right + gap;
            y = anchor.top + (anchor.height() - layer.height()) / 2;
        },
        .left => {
            x = anchor.left - layer.width() - gap;
            y = anchor.top + (anchor.height() - layer.height()) / 2;
        },
        .bottom => {},
    }
    // Never open a layer off the left edge of the window.
    return .{ .x = @max(x, 4), .y = y };
}

fn toggleBool(p: *bool) void {
    p.* = !p.*;
}

// ----------------------------------------------------------------------
// Popover
// ----------------------------------------------------------------------

pub const PopoverArgs = struct {
    style: element.Style = .{},
    open: context.State(bool),
    /// The element the layer is anchored to (rendered inline, always).
    anchor: element.Element,
    /// The floating content, rendered only while `open`.
    content: element.Element,
    side: Side = .bottom,
    gap: f32 = 4,
    key: ?[]const u8 = null,
};

/// A generic floating panel anchored to an element. Layer geometry comes
/// from the previous frame (both the anchor box and the layer's own box),
/// which is exact from the second open frame on; the first frame opens the
/// layer in a default spot below the anchor.
pub fn popover(ctx: *context.Context, args: PopoverArgs) element.Element {
    // The anchor and content come from the caller's render frame; deep-copy
    // them, since the props box is only read later, during reconciliation.
    return ctx.componentProps("popover", Popover.Props{
        .style = args.style,
        .open = args.open,
        .anchor = util.dupElement(ctx.arena, args.anchor) catch
            @panic("zui: out of memory while building the element tree"),
        .content = util.dupElement(ctx.arena, args.content) catch
            @panic("zui: out of memory while building the element tree"),
        .side = args.side,
        .gap = args.gap,
        .key = args.key,
    }, Popover.render);
}

const Popover = struct {
    const Props = struct {
        style: element.Style,
        open: context.State(bool),
        anchor: element.Element,
        content: element.Element,
        side: Side,
        gap: f32,
        key: ?[]const u8,
    };

    const State = struct {
        host: ?*node_mod.Node = null,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        var st = ctx.useState(State, .{});
        st.ptr.host = ctx.node;

        var children: [2]element.Element = .{ props.anchor, .{ .none = {} } };
        var n: usize = 1;
        if (props.open.get()) {
            const host = hostBox(st.ptr.host) orelse skia.Rect{
                .left = 0,
                .top = 0,
                .right = 0,
                .bottom = 0,
            };
            const anchor_box = childBox(st.ptr.host, 0) orelse host;
            const layer_box = childBox(st.ptr.host, 1) orelse skia.Rect{
                .left = anchor_box.left,
                .top = anchor_box.bottom + props.gap,
                .right = anchor_box.left + 120,
                .bottom = anchor_box.bottom + props.gap + 40,
            };
            const pos = placeLayer(anchor_box, layer_box, props.side, props.gap);

            var lstyle = element.Style{
                .position = .absolute,
                .left = pos.x - host.left,
                .top = pos.y - host.top,
                .background = theme.active.surface,
                .border = .all(1),
                .border_color = theme.active.border,
                .border_radius = 8,
                .overflow = .hidden,
                .direction = .column,
            };
            util.applyUser(&lstyle, props.style);

            children[1] = .{ .rect = .{
                .style = lstyle,
                .children = ctx.arena.dupe(element.Element, &.{props.content}) catch
                    @panic("zui: out of memory while building the element tree"),
            } };
            n = 2;
        }

        var style = element.Style{ .direction = .row };
        util.applyUser(&style, props.style);
        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = ctx.arena.dupe(element.Element, children[0..n]) catch
                @panic("zui: out of memory while building the element tree"),
        } };
    }
};

// ----------------------------------------------------------------------
// Dropdown menu
// ----------------------------------------------------------------------

/// One entry of a dropdown (or context) menu.
pub const MenuItem = struct {
    label: []const u8 = "",
    separator: bool = false,
    disabled: bool = false,
    /// Runs from the message thread, during the event poll, when picked.
    handler: ?element.Handler = null,
};

pub const DropdownArgs = struct {
    style: element.Style = .{},
    open: context.State(bool),
    selected: context.State(u32),
    items: []const MenuItem,
    /// Trigger label; defaults to the selected item's label.
    label: ?[]const u8 = null,
    side: Side = .bottom,
    key: ?[]const u8 = null,
};

/// A dropdown menu: an outline button trigger with a caret, a popover, and
/// a list of pickable items. Picking an item sets `selected`, closes the
/// menu and fires the item's handler; clicking the trigger again or
/// pressing Escape also closes it.
pub fn dropdown(ctx: *context.Context, args: DropdownArgs) element.Element {
    return ctx.componentProps("dropdown", Dropdown.Props{
        .style = args.style,
        .open = args.open,
        .selected = args.selected,
        .items = args.items,
        .label = args.label,
        .side = args.side,
        .key = args.key,
    }, Dropdown.render);
}

const Dropdown = struct {
    const Props = struct {
        style: element.Style,
        open: context.State(bool),
        selected: context.State(u32),
        items: []const MenuItem,
        label: ?[]const u8,
        side: Side,
        key: ?[]const u8,
    };

    const State = struct {
        open: ?*bool = null,
        selected: ?*u32 = null,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        var st = ctx.useState(State, .{});
        st.ptr.open = props.open.ptr;
        st.ptr.selected = props.selected.ptr;

        const sel_idx = props.selected.get();
        const trigger_label = props.label orelse
            (if (sel_idx < props.items.len) props.items[sel_idx].label else "");

        const trigger = button_mod.button(ctx, .{
            .label = trigger_label,
            .icon = &icons.caret_down,
            .variant = .outline,
            .onclick = props.open.handler(toggleBool),
        });

        // The menu list: one item component per entry.
        const rows = ctx.arena.alloc(element.Element, props.items.len) catch
            @panic("zui: out of memory while building the element tree");
        for (props.items, 0..) |item, i| {
            rows[i] = ctx.componentProps("dropdownItem", ItemProps{
                .st = st.ptr,
                .index = @as(u32, @intCast(i)),
                .item = item,
            }, dropdownItem);
        }

        const menu = element.Element{
            .rect = .{
                .style = .{
                    .direction = .column,
                    .padding = .all(4),
                    .gap = 2,
                    .min_width = 160,
                    .max_height = 320,
                    .overflow = .hidden,
                },
                .children = rows,
                // Focus lives on the menu itself so Escape reaches it.
                .focusable = true,
                .onkey = .{ .func = onMenuKey, .data = st.ptr },
            },
        };

        return popover(ctx, .{
            .style = props.style,
            .open = props.open,
            .anchor = trigger,
            .content = menu,
            .side = props.side,
            .key = props.key,
        });
    }
};

fn onMenuKey(p: *anyopaque, ev: *const events.Event.KeyEvent) void {
    const st: *Dropdown.State = @ptrCast(@alignCast(p));
    if (ev.key == .escape) {
        if (st.open) |o| o.* = false;
    }
}

const ItemProps = struct {
    st: *Dropdown.State,
    index: u32,
    item: MenuItem,
};

/// One row of the dropdown list.
fn dropdownItem(ctx: *context.Context, props: ItemProps) element.Element {
    const t = theme.active;
    const item = props.item;
    const index = props.index;
    const st = props.st;
    var ist = ctx.useState(ItemState, .{});
    ist.ptr.handler = item.handler;
    ist.ptr.menu = st;
    ist.ptr.index = index;

    if (item.separator) {
        return element.Element{ .rect = .{
            .style = .{ .height = 1, .flex_shrink = 0, .margin = .{ .top = 3, .bottom = 3 }, .background = t.border },
        } };
    }

    const sel = if (st.selected) |s| (s.* == index) else false;
    return element.Element{ .rect = .{
        .style = .{
            .direction = .row,
            .align_items = .center,
            .gap = 8,
            .padding = .{ .left = 8, .right = 12, .top = 6, .bottom = 6 },
            .border_radius = 5,
            .background = if (sel) t.muted else 0,
            .flex_shrink = 0,
        },
        .children = util.dupElements(ctx.arena, &.{
            .{ .text = .{
                .style = .{
                    .color = if (item.disabled) theme.mix(t.foreground, t.background, 0.5) else t.foreground,
                    .font_size = 13,
                },
                .content = item.label,
            } },
        }) catch @panic("zui: out of memory while building the element tree"),
        .onclick = if (!item.disabled) .{ .func = onPickItem, .data = ist.ptr } else null,
        .cursor = if (item.disabled) null else .hand,
    } };
}

const ItemState = struct {
    handler: ?element.Handler = null,
    menu: ?*Dropdown.State = null,
    index: u32 = 0,
};

fn onPickItem(p: *anyopaque) void {
    const ist: *ItemState = @ptrCast(@alignCast(p));
    if (ist.menu) |m| {
        if (m.selected) |s| s.* = ist.index;
        if (m.open) |o| o.* = false;
    }
    if (ist.handler) |h| h.func(h.data);
}

// ----------------------------------------------------------------------
// Tooltip
// ----------------------------------------------------------------------

pub const TooltipArgs = struct {
    style: element.Style = .{},
    /// The element to hover for the tip.
    child: element.Element,
    content: []const u8 = "",
    /// Hover time before the tip appears.
    delay_ms: u32 = 500,
    side: Side = .top,
    gap: f32 = 6,
    key: ?[]const u8 = null,
};

/// A hover tooltip over `child`. Like the popover, the pill is positioned
/// against the previous frame's boxes, so it settles one frame in.
pub fn tooltip(ctx: *context.Context, args: TooltipArgs) element.Element {
    return ctx.componentProps("tooltip", Tooltip.Props{
        .style = args.style,
        .child = util.dupElement(ctx.arena, args.child) catch
            @panic("zui: out of memory while building the element tree"),
        .content = args.content,
        .delay_ms = args.delay_ms,
        .side = args.side,
        .gap = args.gap,
        .key = args.key,
    }, Tooltip.render);
}

const Tooltip = struct {
    const Props = struct {
        style: element.Style,
        child: element.Element,
        content: []const u8,
        delay_ms: u32,
        side: Side,
        gap: f32,
        key: ?[]const u8,
    };

    const State = struct {
        host: ?*node_mod.Node = null,
        hovered: bool = false,
        since_ms: u64 = 0,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        var st = ctx.useState(State, .{});
        st.ptr.host = ctx.node;

        var children: [2]element.Element = .{ props.child, .{ .none = {} } };
        var n: usize = 1;
        const visible = st.ptr.hovered and skia.millis() >= st.ptr.since_ms and
            (skia.millis() - st.ptr.since_ms >= props.delay_ms);
        if (visible) {
            const host = hostBox(st.ptr.host) orelse skia.Rect{
                .left = 0,
                .top = 0,
                .right = 0,
                .bottom = 0,
            };
            const anchor_box = childBox(st.ptr.host, 0) orelse host;
            const pill_box = childBox(st.ptr.host, 1) orelse skia.Rect{
                .left = anchor_box.left,
                .top = anchor_box.top,
                .right = anchor_box.left + 80,
                .bottom = anchor_box.top + 28,
            };
            const pos = placeLayer(anchor_box, pill_box, props.side, props.gap);

            children[1] = .{ .rect = .{
                .style = .{
                    .position = .absolute,
                    .left = pos.x - host.left,
                    .top = pos.y - host.top,
                    .background = 0xFF111114,
                    .border_radius = 5,
                    .padding = .{ .left = 7, .right = 7, .top = 4, .bottom = 4 },
                    .flex_shrink = 0,
                },
                .children = util.dupElements(ctx.arena, &.{
                    .{ .text = .{
                        .style = .{ .color = 0xFFEDEDED, .font_size = 12, .line_height = 1.2 },
                        .content = props.content,
                    } },
                }) catch @panic("zui: out of memory while building the element tree"),
            } };
            n = 2;
        }

        var style = element.Style{ .direction = .row };
        util.applyUser(&style, props.style);
        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = ctx.arena.dupe(element.Element, children[0..n]) catch
                @panic("zui: out of memory while building the element tree"),
            .onmouseenter = .{ .func = tipEnter, .data = st.ptr },
            .onmouseleave = .{ .func = tipLeave, .data = st.ptr },
        } };
    }
};

fn tipEnter(p: *anyopaque) void {
    const st: *Tooltip.State = @ptrCast(@alignCast(p));
    if (!st.hovered) {
        st.since_ms = skia.millis();
    }
    st.hovered = true;
}

fn tipLeave(p: *anyopaque) void {
    const st: *Tooltip.State = @ptrCast(@alignCast(p));
    st.hovered = false;
}

// ----------------------------------------------------------------------
// Modal dialog
// ----------------------------------------------------------------------

pub const ModalArgs = struct {
    open: context.State(bool),
    /// The dialog panel the caller builds.
    content: element.Element,
    /// Click on the scrim or press Escape closes the dialog.
    closable: bool = true,
    key: ?[]const u8 = null,
};

/// A modal dialog. Render it as the last child of a viewport-sized rect
/// (the app root): the dialog is a full-bleed absolute scrim that centers
/// `content` and swallows clicks behind it.
pub fn modal(ctx: *context.Context, args: ModalArgs) element.Element {
    return ctx.componentProps("modal", Modal.Props{
        .open = args.open,
        .content = util.dupElement(ctx.arena, args.content) catch
            @panic("zui: out of memory while building the element tree"),
        .closable = args.closable,
        .key = args.key,
    }, Modal.render);
}

const Modal = struct {
    const Props = struct {
        open: context.State(bool),
        content: element.Element,
        closable: bool,
        key: ?[]const u8,
    };

    const State = struct {
        open: ?*bool = null,
        closable: bool = true,
        host: ?*node_mod.Node = null,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        var st = ctx.useState(State, .{});
        st.ptr.open = props.open.ptr;
        st.ptr.closable = props.closable;
        st.ptr.host = ctx.node;

        if (!props.open.get()) return .{ .none = {} };

        // Center the panel over the window (the component must live in a
        // viewport-sized host, e.g. the app root).
        const vw: f32 = if (ctx.window) |w| @floatFromInt(w.width) else 800;
        const vh: f32 = if (ctx.window) |w| @floatFromInt(w.height) else 600;
        const panel = childBox(st.ptr.host, 1) orelse skia.Rect{
            .left = vw / 2 - 140,
            .top = vh / 2 - 60,
            .right = vw / 2 + 140,
            .bottom = vh / 2 + 60,
        };

        // A full-bleed click catcher behind the panel: the panel is its
        // younger sibling, so clicks that land on the panel never reach the
        // catcher (they are not its ancestors), while everything else closes
        // the dialog.
        const catcher = element.Element{ .rect = .{
            .style = .{
                .position = .absolute,
                .left = 0,
                .top = 0,
                .right = 0,
                .bottom = 0,
            },
            .focusable = true,
            .autofocus = true,
            .onclick = if (props.closable) .{ .func = onCatcherClick, .data = st.ptr } else null,
            .onkey = if (props.closable) .{ .func = onCatcherKey, .data = st.ptr } else null,
        } };
        const panel_el = element.Element{ .rect = .{
            .style = .{
                .position = .absolute,
                .left = (vw - panel.width()) / 2,
                .top = (vh - panel.height()) / 2,
                .background = theme.active.surface,
                .border = .all(1),
                .border_color = theme.active.border,
                .border_radius = 10,
                .direction = .column,
                .overflow = .hidden,
                .flex_shrink = 0,
            },
            .children = ctx.arena.dupe(element.Element, &.{props.content}) catch
                @panic("zui: out of memory while building the element tree"),
        } };

        // The layer that hosts catcher + panel. It has no flow content, so
        // `right`/`bottom` anchoring would size it to the host's (empty)
        // inner box instead of the viewport: size it explicitly.
        return element.Element{ .rect = .{
            .key = props.key,
            .style = .{
                .position = .absolute,
                .left = 0,
                .top = 0,
                .width = vw,
                .height = vh,
                .direction = .row,
                .background = theme.active.scrim,
            },
            .children = ctx.arena.dupe(element.Element, &.{ catcher, panel_el }) catch
                @panic("zui: out of memory while building the element tree"),
        } };
    }
};

fn onCatcherClick(p: *anyopaque) void {
    const st: *Modal.State = @ptrCast(@alignCast(p));
    if (st.closable) {
        if (st.open) |o| o.* = false;
    }
}

fn onCatcherKey(p: *anyopaque, ev: *const events.Event.KeyEvent) void {
    const st: *Modal.State = @ptrCast(@alignCast(p));
    if (st.closable and ev.key == .escape) {
        if (st.open) |o| o.* = false;
    }
}

// ----------------------------------------------------------------------
// Notification toasts
// ----------------------------------------------------------------------

pub const ToastKind = enum {
    info,
    success,
    danger,
};

pub const Toast = struct {
    text: []const u8,
    kind: ToastKind = .info,
    /// When it was queued (frame clock).
    born_ms: u64 = 0,
    /// Lifetime; expired toasts disappear on their own.
    life_ms: u32 = 3200,
};

/// The toast queue. Bounded and process-global: zui apps are single-window,
/// and this keeps the API a plain function call from anywhere.
var toast_buf: [16]?Toast = emptySlots();

fn emptySlots() [16]?Toast {
    var slots: [16]?Toast = undefined;
    for (&slots) |*slot| slot.* = null;
    return slots;
}

/// Queue a notification; `text` must outlive the toast (a literal usually).
pub fn pushToast(text: []const u8, kind: ToastKind, life_ms: u32) void {
    const t = Toast{ .text = text, .kind = kind, .born_ms = skia.millis(), .life_ms = life_ms };
    for (&toast_buf) |*slot| {
        if (slot.* == null) {
            slot.* = t;
            return;
        }
    }
    // Full: overwrite the oldest.
    var oldest: usize = 0;
    var oldest_born: u64 = std.math.maxInt(u64);
    for (toast_buf, 0..) |slot, i| {
        if (slot) |s| {
            if (s.born_ms <= oldest_born) {
                oldest_born = s.born_ms;
                oldest = i;
            }
        }
    }
    toast_buf[oldest] = t;
}

/// Drop every queued toast.
pub fn clearToasts() void {
    for (&toast_buf) |*slot| slot.* = null;
}

/// How many toasts are currently queued (and not yet expired).
pub fn toastCount() usize {
    var n: usize = 0;
    const now = skia.millis();
    for (toast_buf) |slot| {
        if (slot) |s| {
            if (now >= s.born_ms and now - s.born_ms < s.life_ms) n += 1;
        }
    }
    return n;
}

pub const ToasterArgs = struct {
    style: element.Style = .{},
    key: ?[]const u8 = null,
};

/// The toast stack, top-right of its host rect. Render it as the last child
/// of a viewport-sized rect (the app root) so it floats above everything.
pub fn toaster(ctx: *context.Context, args: ToasterArgs) element.Element {
    const t = theme.active;
    const now = skia.millis();

    // Drop expired toasts here (render is the only place that runs
    // regularly; the queue is bounded anyway).
    for (&toast_buf) |*slot| {
        if (slot.*) |s| {
            if (now >= s.born_ms and now - s.born_ms >= s.life_ms) slot.* = null;
        }
    }

    var visible: [16]element.Element = undefined;
    var n: usize = 0;
    for (toast_buf) |slot| {
        const toast = slot orelse continue;
        const accent = switch (toast.kind) {
            .info => t.primary,
            .success => t.success,
            .danger => t.danger,
        };
        visible[n] = .{ .rect = .{
            .style = .{
                .direction = .row,
                .align_items = .center,
                .gap = 8,
                .background = theme.mix(t.surface, 0xFF111114, 0.97),
                .border = .all(1),
                .border_color = theme.mix(accent, t.surface, 0.35),
                .border_radius = 8,
                .padding = .{ .left = 10, .right = 12, .top = 8, .bottom = 8 },
                .flex_shrink = 0,
            },
            .children = util.dupElements(ctx.arena, &.{
                .{ .shape = .{
                    .style = .{ .width = 8, .height = 8, .background = accent, .flex_shrink = 0 },
                    .ops = icons.circleOps(ctx.arena, 12, 12, 10) catch &.{},
                    .fill = true,
                    .view = 24,
                } },
                .{ .text = .{
                    .style = .{ .color = 0xFFEDEDED, .font_size = 13 },
                    .content = toast.text,
                } },
            }) catch @panic("zui: out of memory while building the element tree"),
        } };
        n += 1;
    }

    var style = element.Style{
        .position = .absolute,
        .right = 16,
        .top = 16,
        .direction = .column,
        .gap = 8,
        .align_items = .flex_end,
    };
    util.applyUser(&style, args.style);
    if (n == 0) {
        return element.Element{ .rect = .{ .key = args.key, .style = style } };
    }
    return element.Element{ .rect = .{
        .key = args.key,
        .style = style,
        .children = ctx.arena.dupe(element.Element, visible[0..n]) catch
            @panic("zui: out of memory while building the element tree"),
    } };
}
