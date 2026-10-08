//! Status pieces: badges, tags, progress meters, spinners, skeletons,
//! avatars, keyboard hints and dividers.
//!
//! None of these are interactive (a closeable `tag` is the exception), so
//! they compose `rect`, `text` and `shape` over `theme.active` colors.

const std = @import("std");
const element = @import("../element.zig");
const context = @import("../context.zig");
const node_mod = @import("../node.zig");
const skia = @import("../skia.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const util = @import("util.zig");

/// The box of the component's rendered root from the previous frame; the
/// expansion only exists after reconciliation.
fn hostBox(host: ?*node_mod.Node) ?skia.Rect {
    const comp = host orelse return null;
    const child = comp.child orelse return null;
    return child.bounds();
}

// ----------------------------------------------------------------------
// Badge
// ----------------------------------------------------------------------

pub const BadgeArgs = struct {
    style: element.Style = .{},
    text: []const u8 = "",
    /// Accent color; 0 keeps the theme primary.
    color: u32 = 0,
    key: ?[]const u8 = null,
};

/// A small colored pill: a count, a status, a category.
pub fn badge(ctx: *context.Context, args: BadgeArgs) element.Element {
    const t = theme.active;
    const bg = if (args.color != 0) args.color else t.primary;
    var style = element.Style{
        .direction = .row,
        .align_items = .center,
        .justify_content = .center,
        .background = bg,
        .border_radius = 9,
        .padding = .{ .left = 6, .right = 6, .top = 1, .bottom = 1 },
        .min_width = 18,
        .height = 18,
        .flex_shrink = 0,
    };
    util.applyUser(&style, args.style);
    return element.Element{ .rect = .{
        .key = args.key,
        .style = style,
        .children = util.dupElements(ctx.arena, &.{
            .{ .text = .{
                .style = .{ .color = theme.contrast(bg), .font_size = 11, .line_height = 1.2 },
                .content = args.text,
            } },
        }) catch @panic("zui: out of memory while building the element tree"),
    } };
}

// ----------------------------------------------------------------------
// Tag
// ----------------------------------------------------------------------

pub const TagArgs = struct {
    style: element.Style = .{},
    text: []const u8 = "",
    /// Accent color; 0 mutes the tag.
    color: u32 = 0,
    closable: bool = true,
    /// Fired when the x is pressed.
    onclose: ?element.Handler = null,
    key: ?[]const u8 = null,
};

/// A closable tag (chip).
pub fn tag(ctx: *context.Context, args: TagArgs) element.Element {
    return ctx.componentProps("tag", Tag.Props{
        .style = args.style,
        .text = args.text,
        .color = args.color,
        .closable = args.closable,
        .onclose = args.onclose,
        .key = args.key,
    }, Tag.render);
}

const Tag = struct {
    const Props = struct {
        style: element.Style,
        text: []const u8,
        color: u32,
        closable: bool,
        onclose: ?element.Handler,
        key: ?[]const u8,
    };

    const State = struct {
        onclose: ?element.Handler = null,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        var st = ctx.useState(State, .{});
        st.ptr.onclose = props.onclose;

        const bg = if (props.color != 0) theme.withAlpha(props.color, 0x2E) else t.muted;
        const fg = if (props.color != 0) props.color else t.foreground;

        var close: element.Element = .{ .none = {} };
        if (props.closable) {
            close = .{ .rect = .{
                .style = .{
                    .width = 14,
                    .height = 14,
                    .flex_shrink = 0,
                    .align_items = .center,
                    .justify_content = .center,
                },
                .children = util.dupElements(ctx.arena, &.{.{ .shape = .{
                    .style = .{ .width = 9, .height = 9, .background = fg },
                    .ops = &icons.x_mark,
                    .fill = false,
                    .stroke_width = 2.2,
                    .view = 24,
                } }}) catch @panic("zui: out of memory while building the element tree"),
                .onclick = .{ .func = onClose, .data = st.ptr },
                .cursor = .hand,
            } };
        }

        var style = element.Style{
            .direction = .row,
            .align_items = .center,
            .gap = 5,
            .border_radius = 11,
            .background = bg,
            .flex_shrink = 0,
        };
        util.applyUser(&style, props.style);
        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = ctx.arena.dupe(element.Element, &.{
                .{ .text = .{
                    .style = .{ .color = fg, .font_size = 12, .line_height = 1.2 },
                    .content = props.text,
                } },
                close,
            }) catch @panic("zui: out of memory while building the element tree"),
        } };
    }
};

fn onClose(p: *anyopaque) void {
    const st: *Tag.State = @ptrCast(@alignCast(p));
    if (st.onclose) |h| h.func(h.data);
}

// ----------------------------------------------------------------------
// Linear progress
// ----------------------------------------------------------------------

pub const ProgressArgs = struct {
    style: element.Style = .{},
    /// Fraction complete (clamped to 0..1).
    value: f32 = 0,
    key: ?[]const u8 = null,
};

/// A linear progress meter. The track width (for the percentage fill) comes
/// from the previous frame's layout, so the very first frame draws an empty
/// bar; from then on it is exact.
pub fn progress(ctx: *context.Context, args: ProgressArgs) element.Element {
    return ctx.componentProps("progress", Progress.Props{
        .style = args.style,
        .value = args.value,
        .key = args.key,
    }, Progress.render);
}

const Progress = struct {
    const Props = struct {
        style: element.Style,
        value: f32,
        key: ?[]const u8,
    };

    const State = struct {
        host: ?*node_mod.Node = null,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        var st = ctx.useState(State, .{});
        st.ptr.host = ctx.node;

        const frac = std.math.clamp(props.value, 0, 1);
        const track_w: f32 = if (hostBox(st.ptr.host)) |b| @max(b.width(), 1) else 0;
        const fill_w: f32 = @max(frac * track_w, 0);

        var style = element.Style{
            .direction = .row,
            .align_items = .flex_start,
            .background = t.muted,
            .border_radius = 2,
            .overflow = .hidden,
            .height = 4,
            .flex_grow = 1,
            .flex_shrink = 0,
        };
        util.applyUser(&style, props.style);
        if (style.height == null) style.height = 4;

        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = util.dupElements(ctx.arena, &.{
                .{ .rect = .{
                    .style = .{
                        .width = fill_w,
                        .height = if (style.height) |h| h else 4,
                        .flex_shrink = 0,
                        .background = t.primary,
                    },
                } },
            }) catch @panic("zui: out of memory while building the element tree"),
        } };
    }
};

// ----------------------------------------------------------------------
// Circular progress
// ----------------------------------------------------------------------

pub const ProgressCircleArgs = struct {
    /// Element size (the circle fills it).
    size: f32 = 28,
    /// Fraction complete (clamped to 0..1).
    value: f32 = 0,
    /// Stroke width in path units (24-space).
    stroke: f32 = 3,
    style: element.Style = .{},
    key: ?[]const u8 = null,
};

/// A circular progress meter: a muted track ring with the value drawn as an
/// arc from the top.
pub fn progressCircle(ctx: *context.Context, args: ProgressCircleArgs) element.Element {
    return ctx.componentProps("progressCircle", ProgressCircle.Props{
        .size = args.size,
        .value = args.value,
        .stroke = args.stroke,
        .style = args.style,
        .key = args.key,
    }, ProgressCircle.render);
}

const ProgressCircle = struct {
    const Props = struct {
        size: f32,
        value: f32,
        stroke: f32,
        style: element.Style,
        key: ?[]const u8,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        const frac = std.math.clamp(props.value, 0, 1);
        const r: f32 = 10;
        const size = props.style.width orelse props.size;
        const track = icons.circleOps(ctx.arena, 12, 12, r) catch &.{};
        const sweep = frac * 360;
        const value_ops = if (sweep > 0.5)
            icons.arcOps(ctx.arena, 12, 12, r, -90, sweep) catch &.{}
        else
            &[_]element.PathOp{};
        return element.Element{
            .rect = .{
                .key = props.key,
                .style = .{
                    .direction = .row,
                    .align_items = .center,
                    .justify_content = .center,
                    .width = size,
                    .height = props.style.height orelse size,
                    .flex_shrink = 0,
                },
                .children = util.dupElements(ctx.arena, &.{
                    .{ .shape = .{
                        .style = .{ .width = size, .height = size, .background = t.muted },
                        .ops = track,
                        .fill = false,
                        .stroke_width = props.stroke,
                        .view = 24,
                    } },
                    // The value arc sits exactly over the track ring.
                    .{ .shape = .{
                        .style = .{
                            .position = .absolute,
                            .left = 0,
                            .top = 0,
                            .width = size,
                            .height = size,
                            .background = t.primary,
                        },
                        .ops = value_ops,
                        .fill = false,
                        .stroke_width = props.stroke,
                        .view = 24,
                    } },
                }) catch @panic("zui: out of memory while building the element tree"),
            },
        };
    }
};

// ----------------------------------------------------------------------
// Spinner
// ----------------------------------------------------------------------

pub const SpinnerArgs = struct {
    style: element.Style = .{},
    size: f32 = 20,
    color: u32 = 0,
    key: ?[]const u8 = null,
};

/// An indeterminate spinner: an arc sweeping around, driven by the frame
/// clock (`App` renders every frame, so it keeps moving).
pub fn spinner(ctx: *context.Context, args: SpinnerArgs) element.Element {
    const t = theme.active;
    const spin = @mod(@as(f32, @floatFromInt(skia.millis())) / 8, 360);
    const ops = icons.arcOps(ctx.arena, 12, 12, 10, spin, 300) catch &.{};
    return element.Element{ .shape = .{
        .key = args.key,
        .style = .{
            .width = args.size,
            .height = args.size,
            .flex_shrink = if (args.style.flex_shrink == 1) 0 else args.style.flex_shrink,
            .background = if (args.color != 0) args.color else t.primary,
        },
        .ops = ops,
        .fill = false,
        .stroke_width = 2.6,
        .view = 24,
    } };
}

// ----------------------------------------------------------------------
// Skeleton
// ----------------------------------------------------------------------

pub const SkeletonArgs = struct {
    style: element.Style = .{},
    key: ?[]const u8 = null,
};

/// A shimmering placeholder box for loading content: a translucent band
/// sweeps it once per 1.4s.
pub fn skeleton(ctx: *context.Context, args: SkeletonArgs) element.Element {
    const t = theme.active;
    const period: u32 = 1400;
    const phase = @as(f32, @floatFromInt(skia.millis() % period)) / @as(f32, @floatFromInt(period));

    var style = args.style;
    if (style.background == 0) style.background = t.muted;
    style.overflow = .hidden;
    const w = style.width orelse 120;
    const band_w = @max(w * 0.35, 24);
    const band_x = phase * (w + band_w) - band_w;
    return element.Element{ .rect = .{
        .key = args.key,
        .style = .{
            .direction = .row,
            .overflow = .hidden,
            .width = style.width,
            .height = style.height,
            .flex_grow = style.flex_grow,
            .flex_shrink = style.flex_shrink,
            .border_radius = style.border_radius,
            .background = style.background,
        },
        .children = util.dupElements(ctx.arena, &.{
            .{ .rect = .{
                .style = .{
                    .position = .absolute,
                    .left = band_x,
                    .top = 0,
                    .bottom = 0,
                    .width = band_w,
                    .background = 0x33FFFFFF,
                },
            } },
        }) catch @panic("zui: out of memory while building the element tree"),
    } };
}

// ----------------------------------------------------------------------
// Avatar
// ----------------------------------------------------------------------

pub const AvatarArgs = struct {
    text: []const u8 = "",
    background: u32 = 0,
    /// Element size.
    size: f32 = 36,
    style: element.Style = .{},
    key: ?[]const u8 = null,
};

/// A rounded-square avatar with initials (or any short glyph).
pub fn avatar(ctx: *context.Context, args: AvatarArgs) element.Element {
    return ctx.componentProps("avatar", Avatar.Props{
        .text = args.text,
        .background = args.background,
        .size = args.size,
        .style = args.style,
        .key = args.key,
    }, Avatar.render);
}

const Avatar = struct {
    const Props = struct {
        text: []const u8,
        background: u32,
        size: f32,
        style: element.Style,
        key: ?[]const u8,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        const bg = if (props.background != 0) props.background else t.primary;
        const size = props.style.width orelse props.size;
        return element.Element{ .rect = .{
            .key = props.key,
            .style = .{
                .direction = .row,
                .align_items = .center,
                .justify_content = .center,
                .width = size,
                .height = props.style.height orelse size,
                .flex_shrink = 0,
                .border_radius = size * 0.28,
                .background = bg,
            },
            .children = util.dupElements(ctx.arena, &.{
                .{ .text = .{
                    .style = .{
                        .color = theme.contrast(bg),
                        .font_size = size * 0.38,
                        .font_weight = .medium,
                    },
                    .content = props.text,
                } },
            }) catch @panic("zui: out of memory while building the element tree"),
        } };
    }
};

// ----------------------------------------------------------------------
// Kbd + Divider
// ----------------------------------------------------------------------

pub const KbdArgs = struct {
    style: element.Style = .{},
    text: []const u8 = "",
    key: ?[]const u8 = null,
};

/// A keyboard key hint (a menu shortcut, like "Ctrl").
pub fn kbd(ctx: *context.Context, args: KbdArgs) element.Element {
    const t = theme.active;
    return element.Element{ .rect = .{
        .key = args.key,
        .style = .{
            .direction = .row,
            .align_items = .center,
            .justify_content = .center,
            .background = t.muted,
            .border = .all(1),
            .border_color = t.border,
            .border_radius = 4,
            .padding = .{ .left = 5, .right = 5, .top = 2, .bottom = 2 },
            .flex_shrink = 0,
        },
        .children = util.dupElements(ctx.arena, &.{
            .{ .text = .{
                .style = .{ .color = t.muted_foreground, .font_size = 12, .line_height = 1.2 },
                .content = args.text,
            } },
        }) catch @panic("zui: out of memory while building the element tree"),
    } };
}

pub const DividerArgs = struct {
    style: element.Style = .{},
    vertical: bool = false,
    color: u32 = 0,
    key: ?[]const u8 = null,
};

/// A hairline separator: horizontal (a 1px line across the column) by
/// default, vertical in a row.
pub fn divider(args: DividerArgs) element.Element {
    const t = theme.active;
    var style = args.style;
    if (args.vertical) {
        if (style.width == null) style.width = 1;
        if (style.flex_grow == 0) style.flex_grow = 1;
    } else {
        if (style.height == null) style.height = 1;
        style.flex_shrink = 0;
    }
    if (style.background == 0) style.background = if (args.color != 0) args.color else t.border;
    return element.Element{ .rect = .{
        .key = args.key,
        .style = style,
    } };
}
