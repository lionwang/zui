//! Buttons: variants, sizes, icons, loading and disabled states.
//!
//! The visual defaults come from `theme.active`; anything set on
//! `args.style` wins (`background == 0` / `color == 0xFF000000` count as
//! "not set" and fall back to the variant's palette colors).
//!
//! ```zig
//! ui.button(ctx, .{ .label = "Save", .variant = .primary, .onclick = ... })
//! ```

const std = @import("std");
const element = @import("../element.zig");
const context = @import("../context.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const skia = @import("../skia.zig");

/// The visual style of the button surface.
pub const ButtonVariant = enum {
    /// Neutral surface (the workhorse button).
    default,
    /// The accent color: the action the page is about.
    primary,
    /// Transparent until hovered.
    ghost,
    /// Same as ghost plus a border.
    outline,
    /// Destructive action.
    danger,
};

pub const ButtonSize = enum {
    sm,
    md,
    lg,
};

pub const ButtonArgs = struct {
    style: element.Style = .{},
    label: []const u8 = "",
    /// Optional leading icon: path ops in a 24 space.
    icon: ?[]const element.PathOp = null,
    variant: ButtonVariant = .default,
    size: ButtonSize = .md,
    /// Shown dimmed, without hover feedback and without clicks.
    disabled: bool = false,
    /// Replaces the icon with a spinner; the label stays visible.
    loading: bool = false,
    onclick: ?element.Handler = null,
    key: ?[]const u8 = null,
    cursor: ?element.Cursor = .hand,
};

const State = struct {
    hovered: bool = false,
    pressed: bool = false,
};

const Metric = struct { pad: f32, font: f32, radius: f32, icon: f32 };

fn metric(size: ButtonSize) Metric {
    return switch (size) {
        .sm => .{ .pad = 6, .font = 13, .radius = 6, .icon = 13 },
        .md => .{ .pad = 8, .font = 14, .radius = 7, .icon = 15 },
        .lg => .{ .pad = 12, .font = 16, .radius = 8, .icon = 17 },
    };
}

/// The base + text colors a variant paints with (before hover/dim).
fn variantColors(v: ButtonVariant) struct { bg: u32, fg: u32 } {
    const t = theme.active;
    return switch (v) {
        .default => .{ .bg = t.muted, .fg = t.foreground },
        .primary => .{ .bg = t.primary, .fg = t.primary_foreground },
        .ghost => .{ .bg = 0, .fg = t.foreground },
        .outline => .{ .bg = 0, .fg = t.foreground },
        .danger => .{ .bg = t.danger, .fg = t.danger_foreground },
    };
}

fn render(ctx: *context.Context, props: ButtonArgs) element.Element {
    const st = ctx.useState(State, .{});

    const t = theme.active;
    const m = metric(props.size);
    var colors = variantColors(props.variant);
    if (props.style.background != 0) {
        colors.bg = props.style.background;
        // An explicit background with no explicit text color: pick one the
        // caller can read.
        if (props.style.color == 0xFF000000) colors.fg = theme.contrast(colors.bg);
    }
    if (props.style.color != 0xFF000000) colors.fg = props.style.color;

    // Hover lightens (ghosts gain a surface), a press darkens slightly.
    var bg = colors.bg;
    if (!props.disabled) {
        if (st.ptr.hovered) bg = switch (props.variant) {
            .primary => theme.mix(bg, 0xFFFFFFFF, 0.14),
            .danger => theme.mix(bg, 0xFFFFFFFF, 0.14),
            .ghost, .outline, .default => t.surface_hover,
        };
        if (st.ptr.hovered and st.ptr.pressed) bg = theme.mix(bg, 0xFF000000, 0.08);
    } else {
        bg = theme.mix(bg, t.background, 0.55);
        colors.fg = theme.mix(colors.fg, t.background, 0.45);
    }

    var style = props.style;
    style.direction = .row;
    style.align_items = .center;
    style.justify_content = .center;
    style.gap = 7;
    style.background = bg;
    style.border_radius = m.radius;
    // The caller takes over the box geometry when they set a padding.
    if (props.style.padding.horizontal() == 0 and props.style.padding.vertical() == 0) {
        style.padding = .{ .left = m.pad + 2, .right = m.pad + 2, .top = m.pad - 2, .bottom = m.pad - 2 };
    }
    if (props.variant == .outline) {
        style.border = .all(1);
        style.border_color = t.border;
    }

    // Icon or spinner, then the label.
    const glyph_color = if (props.style.background != 0 and props.style.color != 0xFF000000)
        props.style.color
    else
        colors.fg;

    var children: [2]element.Element = .{ .{ .none = {} }, .{ .none = {} } };
    var n_children: usize = 0;
    if (props.loading) {
        const spin = @mod(@as(f32, @floatFromInt(skia.millis())) / 8, 360);
        const ops = icons.arcOps(ctx.arena, 12, 12, 8, spin, 300) catch &.{};
        children[0] = .{ .shape = .{
            .style = .{ .width = m.icon, .height = m.icon, .background = glyph_color },
            .ops = ops,
            .fill = false,
            .stroke_width = 2.4,
            .view = 24,
        } };
        n_children = 1;
    } else if (props.icon) |ops| {
        children[0] = .{ .shape = .{
            .style = .{ .width = m.icon, .height = m.icon, .background = glyph_color },
            .ops = ops,
            .fill = false,
            .stroke_width = 1.8,
            .view = 24,
        } };
        n_children = 1;
    }
    if (props.label.len > 0) {
        children[n_children] = .{ .text = .{
            .style = .{
                .color = colors.fg,
                .font_size = m.font,
                .font_weight = props.style.font_weight orelse .medium,
            },
            .content = props.label,
        } };
        n_children += 1;
    }

    return element.Element{ .rect = .{
        .key = props.key,
        .style = style,
        .children = ctx.arena.dupe(element.Element, children[0..n_children]) catch
            @panic("zui: out of memory while building the element tree"),
        .onclick = if (!props.disabled) props.onclick else null,
        .onmouseenter = if (!props.disabled)
            .{ .func = setHovered, .data = st.ptr }
        else
            null,
        .onmouseleave = if (!props.disabled)
            .{ .func = clearHover, .data = st.ptr }
        else
            null,
        .onmouse = if (!props.disabled)
            .{ .func = onPress, .data = st.ptr }
        else
            null,
        .cursor = if (props.disabled) null else props.cursor,
    } };
}

fn setHovered(p: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(p));
    st.hovered = true;
}

fn clearHover(p: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(p));
    st.hovered = false;
    st.pressed = false;
}

fn onPress(p: *anyopaque, ev: *const element.MouseEvent) void {
    const st: *State = @ptrCast(@alignCast(p));
    if (ev.button != .left) return;
    st.pressed = ev.action == .press;
}

/// A button. `label`, `icon` or both; colors from `theme.active` unless
/// `args.style` sets them.
pub fn button(ctx: *context.Context, args: ButtonArgs) element.Element {
    return ctx.componentProps("button", args, render);
}

/// A square icon button (no label).
pub fn iconButton(ctx: *context.Context, args: ButtonArgs) element.Element {
    var a = args;
    a.label = "";
    if (a.style.width == null) a.style.width = if (args.size == .lg) 40 else (if (args.size == .sm) 28 else 34);
    if (a.style.height == null) a.style.height = a.style.width.?;
    a.style.padding = .all(5);
    return ctx.componentProps("iconButton", a, render);
}
