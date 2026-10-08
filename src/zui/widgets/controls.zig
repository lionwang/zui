//! Form controls: checkbox, switch, radio group, slider, stepper, rating.
//!
//! Each control reads its value from a hook the caller owns
//! (`ctx.useState(...)`), so the state lives where the data model lives:
//! mutations go through the same handle the application reads.
//!
//! Geometry that an event handler needs (the slider track, a rating row) is
//! resolved through the component's retained node at *event* time - the
//! link to its expansion only exists after reconciliation, so the box comes
//! from the previous frame (positions are stable while the widget is used).

const std = @import("std");
const element = @import("../element.zig");
const context = @import("../context.zig");
const node_mod = @import("../node.zig");
const skia = @import("../skia.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const button_mod = @import("button.zig");
const util = @import("util.zig");

fn hostBox(host: ?*node_mod.Node) ?skia.Rect {
    const comp = host orelse return null;
    const child = comp.child orelse return null;
    return child.bounds();
}

// ----------------------------------------------------------------------
// Checkbox
// ----------------------------------------------------------------------

/// Shared visual knobs for the small controls.
pub const ControlArgs = struct {
    style: element.Style = .{},
    disabled: bool = false,
    key: ?[]const u8 = null,
};

/// A labeled checkbox; `checked` is the caller's hook, clicks toggle it.
pub fn checkbox(
    ctx: *context.Context,
    checked: context.State(bool),
    label: []const u8,
    args: ControlArgs,
) element.Element {
    return ctx.componentProps("checkbox", Checkbox.Props{
        .checked = checked,
        .label = label,
        .args = args,
    }, Checkbox.render);
}

const Checkbox = struct {
    const Props = struct {
        checked: context.State(bool),
        label: []const u8,
        args: ControlArgs,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        const on = props.checked.get();
        const dim_border = theme.mix(t.border, t.background, 0.3);

        const box = element.Element{ .rect = .{
            .style = .{
                .width = 16,
                .height = 16,
                .flex_shrink = 0,
                .border_radius = 4,
                .background = if (on) t.primary else 0,
                .border = .all(1.4),
                .border_color = if (on) t.primary else (if (props.args.disabled) dim_border else t.border),
                .align_items = .center,
                .justify_content = .center,
            },
            .children = if (on) util.dupElements(ctx.arena, &.{.{ .shape = .{
                .style = .{ .width = 10, .height = 10, .background = t.primary_foreground },
                .ops = &icons.check,
                .fill = false,
                .stroke_width = 2.2,
                .view = 24,
            } }}) catch @panic("zui: out of memory while building the element tree") else &.{},
        } };

        var children = [_]element.Element{ box, .{ .none = {} } };
        var n: usize = 1;
        if (props.label.len > 0) {
            children[1] = .{ .text = .{
                .style = .{
                    .color = if (props.args.disabled) theme.mix(t.foreground, t.background, 0.5) else t.foreground,
                    .font_size = 14,
                },
                .content = props.label,
            } };
            n = 2;
        }

        var style = props.args.style;
        style.direction = .row;
        style.align_items = .center;
        style.gap = 8;
        return element.Element{ .rect = .{
            .key = props.args.key,
            .style = style,
            .children = ctx.arena.dupe(element.Element, children[0..n]) catch
                @panic("zui: out of memory while building the element tree"),
            .onclick = if (!props.args.disabled) props.checked.handler(toggle) else null,
            .cursor = if (props.args.disabled) null else .hand,
        } };
    }
};

fn toggle(p: *bool) void {
    p.* = !p.*;
}

// ----------------------------------------------------------------------
// Switch
// ----------------------------------------------------------------------

/// A toggle pill; `checked` is the caller's hook.
pub fn switchControl(
    ctx: *context.Context,
    checked: context.State(bool),
    args: ControlArgs,
) element.Element {
    return ctx.componentProps("switch", Switch.Props{
        .checked = checked,
        .args = args,
    }, Switch.render);
}

const Switch = struct {
    const Props = struct {
        checked: context.State(bool),
        args: ControlArgs,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        const on = props.checked.get();
        const track_bg = if (on)
            t.primary
        else if (props.args.disabled)
            t.muted
        else
            theme.mix(t.border, t.background, 0.2);

        const knob = element.Element{ .rect = .{
            .style = .{
                .width = 16,
                .height = 16,
                .flex_shrink = 0,
                .border_radius = 8,
                .background = 0xFFFFFFFF,
            },
        } };

        var style = props.args.style;
        style.direction = .row;
        style.align_items = .center;
        style.width = 38;
        style.height = 22;
        style.flex_shrink = 0;
        style.border_radius = 11;
        style.background = track_bg;
        style.padding = .{ .left = 3, .right = 3 };
        style.justify_content = if (on) .flex_end else .flex_start;
        return element.Element{ .rect = .{
            .key = props.args.key,
            .style = style,
            .children = ctx.arena.dupe(element.Element, &.{knob}) catch
                @panic("zui: out of memory while building the element tree"),
            .onclick = if (!props.args.disabled) props.checked.handler(toggle) else null,
            .cursor = if (props.args.disabled) null else .hand,
        } };
    }
};

// ----------------------------------------------------------------------
// Radio group
// ----------------------------------------------------------------------

pub const RadioGroupArgs = struct {
    style: element.Style = .{},
    selected: context.State(u32),
    /// One label per option, in order.
    labels: []const []const u8,
    direction: element.Direction = .column,
    disabled: bool = false,
    key: ?[]const u8 = null,
};

/// A mutually exclusive group: the selected index lives in the caller's
/// `State(u32)` hook.
pub fn radioGroup(ctx: *context.Context, args: RadioGroupArgs) element.Element {
    return ctx.componentProps("radioGroup", RadioGroup.Props{
        .style = args.style,
        .selected = args.selected,
        .labels = args.labels,
        .direction = args.direction,
        .disabled = args.disabled,
        .key = args.key,
    }, RadioGroup.render);
}

const RadioGroup = struct {
    const Props = struct {
        style: element.Style,
        selected: context.State(u32),
        labels: []const []const u8,
        direction: element.Direction,
        disabled: bool,
        key: ?[]const u8,
    };

    /// Per-item link between the shared selection hook and the item's index.
    /// Handlers must read data owned by a node hook (arena pointers are
    /// freed with the frame), so each item keeps one of these.
    const ItemState = struct {
        selected: ?*u32 = null,
        index: u32 = 0,
    };

    const ItemProps = struct {
        selected: context.State(u32),
        disabled: bool,
        index: u32,
        label: []const u8,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const items = ctx.arena.alloc(element.Element, props.labels.len) catch
            @panic("zui: out of memory while building the element tree");
        for (props.labels, 0..) |label, i| {
            items[i] = ctx.componentProps("radioItem", ItemProps{
                .selected = props.selected,
                .disabled = props.disabled,
                .index = @as(u32, @intCast(i)),
                .label = label,
            }, radioItemRender);
        }
        var style = props.style;
        style.direction = props.direction;
        style.align_items = .flex_start;
        if (style.gap == 0) style.gap = 6;
        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = items,
        } };
    }
};

fn radioItemRender(ctx: *context.Context, props: RadioGroup.ItemProps) element.Element {
    const t = theme.active;
    var st = ctx.useState(RadioGroup.ItemState, .{});
    st.ptr.selected = props.selected.ptr;
    st.ptr.index = props.index;

    const on = props.selected.get() == props.index;
    const ring_color = if (props.disabled)
        theme.mix(t.border, t.background, 0.3)
    else if (on)
        t.primary
    else
        t.border;

    const dot: element.Element = if (on) .{ .shape = .{
        .style = .{ .width = 8, .height = 8, .background = t.primary },
        .ops = icons.circleOps(ctx.arena, 12, 12, 9) catch &.{},
        .fill = true,
        .view = 24,
    } } else .{ .none = {} };

    return element.Element{ .rect = .{
        .style = .{
            .direction = .row,
            .align_items = .center,
            .gap = 8,
            .padding = .{ .top = 3, .bottom = 3 },
        },
        .children = ctx.arena.dupe(element.Element, &.{
            .{ .shape = .{
                .style = .{ .width = 16, .height = 16, .background = ring_color },
                .ops = icons.circleOps(ctx.arena, 12, 12, 9) catch &.{},
                .fill = false,
                .stroke_width = 1.8,
                .view = 24,
            } },
            dot,
            .{ .text = .{
                .style = .{
                    .color = if (props.disabled) theme.mix(t.foreground, t.background, 0.5) else t.foreground,
                    .font_size = 14,
                },
                .content = props.label,
            } },
        }) catch @panic("zui: out of memory while building the element tree"),
        .onclick = if (!props.disabled) .{ .func = onPickRadio, .data = st.ptr } else null,
        .cursor = if (props.disabled) null else .hand,
    } };
}

fn onPickRadio(p: *anyopaque) void {
    const st: *RadioGroup.ItemState = @ptrCast(@alignCast(p));
    if (st.selected) |ptr| ptr.* = st.index;
}

// ----------------------------------------------------------------------
// Slider
// ----------------------------------------------------------------------

pub const SliderArgs = struct {
    style: element.Style = .{},
    /// The value, in the caller's units (clamped to [min, max]).
    value: context.State(f32),
    min: f32 = 0,
    max: f32 = 100,
    /// > 0 snaps to multiples of `step` (from `min`).
    step: f32 = 0,
    disabled: bool = false,
    key: ?[]const u8 = null,
};

/// A drag slider: press anywhere on the track jumps to the pointer, the
/// drag keeps mapping it; the handle and fill follow the hook.
pub fn slider(ctx: *context.Context, args: SliderArgs) element.Element {
    return ctx.componentProps("slider", Slider.Props{
        .style = args.style,
        .value = args.value,
        .min = args.min,
        .max = args.max,
        .step = args.step,
        .disabled = args.disabled,
        .key = args.key,
    }, Slider.render);
}

const Slider = struct {
    const Props = struct {
        style: element.Style,
        value: context.State(f32),
        min: f32,
        max: f32,
        step: f32,
        disabled: bool,
        key: ?[]const u8,
    };

    const State = struct {
        value: ?*f32 = null,
        min: f32 = 0,
        max: f32 = 100,
        step: f32 = 0,
        /// The component node; `host.child` is the slider root rect.
        host: ?*node_mod.Node = null,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        var st = ctx.useState(State, .{});
        st.ptr.value = props.value.ptr;
        st.ptr.min = props.min;
        st.ptr.max = props.max;
        st.ptr.step = props.step;
        st.ptr.host = ctx.node;

        const span = @max(props.max - props.min, 0.0001);
        const frac = std.math.clamp((props.value.get() - props.min) / span, 0, 1);
        // Track geometry comes from the previous frame (stable while the
        // slider is dragged - the track never moves).
        const track_w: f32 = if (hostBox(st.ptr.host)) |b| @max(b.width(), 1) else 100;
        const fill_w = @max(frac * track_w, 0);

        return element.Element{
            .rect = .{
                .key = props.key,
                .style = .{
                    .direction = .row,
                    .align_items = .center,
                    .height = props.style.height orelse 22,
                    .width = props.style.width,
                    .flex_grow = props.style.flex_grow,
                    .padding = props.style.padding,
                    .margin = props.style.margin,
                },
                .children = util.dupElements(ctx.arena, &.{.{
                    .rect = .{
                        .style = .{
                            .flex_grow = 1,
                            .height = 4,
                            .border_radius = 2,
                            .background = if (props.disabled) theme.mix(t.border, t.background, 0.2) else t.muted,
                            .align_items = .center,
                        },
                        .children = &.{
                            .{ .rect = .{
                                .style = .{
                                    .width = fill_w,
                                    .height = 4,
                                    .flex_shrink = 0,
                                    .border_radius = 2,
                                    .background = t.primary,
                                },
                            } },
                            // The handle is centered on the fill end: absolute, its
                            // circle standing over the track.
                            .{ .rect = .{
                                .style = .{
                                    .position = .absolute,
                                    .left = fill_w - 8,
                                    .top = -6,
                                    .width = 16,
                                    .height = 16,
                                    .border_radius = 8,
                                    .background = 0xFFFFFFFF,
                                    .border = .all(1.6),
                                    .border_color = t.primary,
                                },
                            } },
                        },
                    },
                }}) catch @panic("zui: out of memory while building the element tree"),
                .cursor = if (props.disabled) null else .hand,
                .onmouse = if (!props.disabled) .{ .func = onMouse, .data = st.ptr } else null,
            },
        };
    }
};

/// Press, drag or release: map the pointer onto the track (the release
/// commits the value at the drop point).
fn onMouse(p: *anyopaque, ev: *const element.MouseEvent) void {
    const st: *Slider.State = @ptrCast(@alignCast(p));
    if (ev.button != .left) return;
    const comp = st.host orelse return;
    const root = comp.child orelse return;
    if (root.children.items.len == 0) return;
    const b = root.children.items[0].bounds();
    const frac = std.math.clamp((ev.x - b.left) / @max(b.width(), 0.0001), 0, 1);
    const span = @max(st.max - st.min, 0.0001);
    var v = st.min + frac * span;
    if (st.step > 0) v = st.min + @round((v - st.min) / st.step) * st.step;
    v = std.math.clamp(v, st.min, st.max);
    if (st.value) |ptr| ptr.* = v;
}

// ----------------------------------------------------------------------
// Stepper
// ----------------------------------------------------------------------

pub const StepperArgs = struct {
    style: element.Style = .{},
    value: context.State(f32),
    min: f32 = 0,
    max: f32 = 1e9,
    step: f32 = 1,
    disabled: bool = false,
    key: ?[]const u8 = null,
};

/// A numeric stepper: minus / plus buttons around the (formatted) value.
pub fn stepper(ctx: *context.Context, args: StepperArgs) element.Element {
    return ctx.componentProps("stepper", Stepper.Props{
        .style = args.style,
        .value = args.value,
        .min = args.min,
        .max = args.max,
        .step = args.step,
        .disabled = args.disabled,
        .key = args.key,
    }, Stepper.render);
}

const Stepper = struct {
    const Props = struct {
        style: element.Style,
        value: context.State(f32),
        min: f32,
        max: f32,
        step: f32,
        disabled: bool,
        key: ?[]const u8,
    };

    const State = struct {
        value: ?*f32 = null,
        min: f32 = 0,
        max: f32 = 1,
        step: f32 = 1,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        var st = ctx.useState(State, .{});
        st.ptr.value = props.value.ptr;
        st.ptr.min = props.min;
        st.ptr.max = props.max;
        st.ptr.step = props.step;

        const dec = button_mod.iconButton(ctx, .{
            .icon = &icons.minus,
            .size = .sm,
            .variant = .outline,
            .disabled = props.disabled or props.value.get() <= props.min,
            .onclick = .{ .func = stepDown, .data = st.ptr },
        });
        const inc = button_mod.iconButton(ctx, .{
            .icon = &icons.plus,
            .size = .sm,
            .variant = .outline,
            .disabled = props.disabled or props.value.get() >= props.max,
            .onclick = .{ .func = stepUp, .data = st.ptr },
        });

        return element.Element{ .rect = .{
            .key = props.key,
            .style = .{
                .direction = .row,
                .align_items = .center,
                .gap = 6,
                .width = props.style.width,
                .justify_content = props.style.justify_content,
                .flex_grow = props.style.flex_grow,
            },
            .children = util.dupElements(ctx.arena, &.{
                dec,
                .{ .text = .{
                    .style = .{
                        .color = if (props.disabled) theme.mix(t.foreground, t.background, 0.5) else t.foreground,
                        .font_size = 14,
                        .width = 40,
                        .text_align = .center,
                    },
                    .content = std.fmt.allocPrint(ctx.arena, "{d}", .{props.value.get()}) catch "?",
                } },
                inc,
            }) catch @panic("zui: out of memory while building the element tree"),
        } };
    }
};

fn applyStep(st: *Stepper.State, delta: f32) void {
    if (st.value) |ptr| {
        ptr.* = std.math.clamp(ptr.* + delta * st.step, st.min, st.max);
    }
}

fn stepUp(p: *anyopaque) void {
    applyStep(@ptrCast(@alignCast(p)), 1);
}

fn stepDown(p: *anyopaque) void {
    applyStep(@ptrCast(@alignCast(p)), -1);
}

// ----------------------------------------------------------------------
// Rating
// ----------------------------------------------------------------------

pub const RatingArgs = struct {
    style: element.Style = .{},
    /// How many stars are selected (0 .. max).
    value: context.State(u32),
    max: u32 = 5,
    disabled: bool = false,
    key: ?[]const u8 = null,
};

/// A star rating: hover previews the choice, a click selects it, a drag
/// selects where it lands.
pub fn rating(ctx: *context.Context, args: RatingArgs) element.Element {
    return ctx.componentProps("rating", Rating.Props{
        .style = args.style,
        .value = args.value,
        .max = args.max,
        .disabled = args.disabled,
        .key = args.key,
    }, Rating.render);
}

const Rating = struct {
    const Props = struct {
        style: element.Style,
        value: context.State(u32),
        max: u32,
        disabled: bool,
        key: ?[]const u8,
    };

    const State = struct {
        value: ?*u32 = null,
        max: u32 = 5,
        /// Preview count while the cursor is over the stars.
        hovered: u32 = 0,
        host: ?*node_mod.Node = null,
    };

    /// Per-star hover state (each star is its own component with its own hook).
    const StarState = struct {
        rating: ?*State = null,
        index: u32 = 0,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        var st = ctx.useState(State, .{});
        st.ptr.value = props.value.ptr;
        st.ptr.max = props.max;
        st.ptr.host = ctx.node;

        const stars = ctx.arena.alloc(element.Element, props.max) catch
            @panic("zui: out of memory while building the element tree");
        var i: u32 = 0;
        while (i < props.max) : (i += 1) {
            stars[i] = ctx.componentProps("star", StarProps{
                .rating = st.ptr,
                .index = i,
                .lit = i < (if (st.ptr.hovered > 0) st.ptr.hovered else props.value.get()),
                .disabled = props.disabled,
            }, starRender);
        }
        var style = props.style;
        style.direction = .row;
        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = stars,
            .onmouse = if (!props.disabled) .{ .func = ratingMouse, .data = st.ptr } else null,
        } };
    }
};

const StarProps = struct {
    rating: ?*Rating.State = null,
    index: u32 = 0,
    lit: bool = false,
    disabled: bool = false,
};

fn starRender(ctx: *context.Context, props: StarProps) element.Element {
    const t = theme.active;
    var st = ctx.useState(Rating.StarState, .{});
    st.ptr.rating = props.rating;
    st.ptr.index = props.index;

    return element.Element{ .rect = .{
        .style = .{
            .width = 22,
            .height = 22,
            .flex_shrink = 0,
            .align_items = .center,
            .justify_content = .center,
        },
        .children = util.dupElements(ctx.arena, &.{.{ .shape = .{
            .style = .{
                .width = 16,
                .height = 16,
                .background = if (props.lit) (if (props.disabled) theme.mix(t.warning, t.background, 0.4) else t.warning) else t.border,
            },
            .ops = &icons.star,
            .fill = true,
            .view = 24,
        } }}) catch @panic("zui: out of memory while building the element tree"),
        .onmouseenter = if (!props.disabled) .{ .func = starHover, .data = st.ptr } else null,
        .cursor = if (props.disabled) null else .hand,
    } };
}

fn starHover(p: *anyopaque) void {
    const st: *Rating.StarState = @ptrCast(@alignCast(p));
    if (st.rating) |r| r.hovered = st.index + 1;
}

fn ratingMouse(p: *anyopaque, ev: *const element.MouseEvent) void {
    const st: *Rating.State = @ptrCast(@alignCast(p));
    if (ev.button != .left) return;
    const comp = st.host orelse return;
    const root = comp.child orelse return;

    // Which star is under the cursor: the child whose box contains x.
    var idx: u32 = 0;
    for (root.children.items, 0..) |c, i| {
        const b = c.bounds();
        if (ev.x <= b.right) {
            idx = @intCast(i + 1);
            break;
        }
    }
    switch (ev.action) {
        .press => {
            if (st.value) |ptr| ptr.* = idx;
        },
        .move => st.hovered = idx,
        .release => st.hovered = 0,
    }
}
