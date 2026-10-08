//! ECharts-flavored charts: line / area, bar and pie (donut) charts.
//!
//! The charts are plain zui components: they take their data as argument
//! slices (deep-copied into the per-frame arena, because the caller may build
//! them on its own stack), lay themselves out over their box and draw through
//! absolutely positioned shapes / rects / texts. Geometry comes from the
//! *previous* frame's box - one frame of settle, like the popovers - so a
//! chart needs a definite size (`flex_grow` inside a sized column, or
//! explicit `width` / `height`).
//!
//! Hover tooltips follow the live cursor (`window.cursor_x` / `cursor_y`,
//! updated by the cursor-move callback before the frame renders). Legend
//! pills toggle a series off; that state lives in a hook.
//!
//! Everything drawn inside the plot area is an absolutely positioned child of
//! the plot rect, so all coordinates below are relative to it.

const std = @import("std");
const element = @import("../element.zig");
const context = @import("../context.zig");
const node_mod = @import("../node.zig");
const skia = @import("../skia.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const util = @import("util.zig");

/// ECharts' default category palette.
pub const palette = [_]u32{
    0xFF5470C6, 0xFF91CC75, 0xFFFAC858, 0xFFEE6666, 0xFF73C0DE,
    0xFF3BA272, 0xFFFC8452, 0xFF9A60B4, 0xFFEA7CCC,
};

const max_series = 16;

fn falseFlags() [max_series]bool {
    var flags: [max_series]bool = undefined;
    for (&flags) |*f| f.* = false;
    return flags;
}

fn emptyToggles() [max_series]Toggle {
    var list: [max_series]Toggle = undefined;
    for (&list) |*t| t.* = .{ .state = undefined, .index = 0 };
    return list;
}

fn seriesColor(i: usize, override: u32) u32 {
    if (override != 0) return override;
    return palette[i % palette.len];
}

fn hostBox(host: ?*node_mod.Node) ?skia.Rect {
    const comp = host orelse return null;
    const child = comp.child orelse return null;
    return child.bounds();
}

fn childBox(host: ?*node_mod.Node, i: usize) ?skia.Rect {
    const comp = host orelse return null;
    const root = comp.child orelse return null;
    if (root.children.items.len <= i) return null;
    return root.children.items[i].bounds();
}

/// Plot padding in logical pixels: room for the y tick labels on the left,
/// the x category labels below.
const pad_left: f32 = 44;
const pad_right: f32 = 12;
const pad_top: f32 = 10;
const pad_bottom: f32 = 26;

/// The coordinate space series paths are authored in; the painter stretches
/// the square `view x view` space onto the element box, so one normalization
/// serves any aspect ratio.
const view: f32 = 1000;

const Scale = struct {
    lo: f32,
    hi: f32,
    step: f32,
};

/// Snap a raw data range onto "nice" tick boundaries (1/2/5 x 10^n), the way
/// ECharts computes its axis extents.
fn niceScale(raw_min: f32, raw_max: f32) Scale {
    var min = raw_min;
    var max = raw_max;
    if (max <= min) {
        if (min == 0) {
            max = 1;
        } else if (min > 0) {
            min = 0;
        } else {
            max = 0;
        }
    }
    var step = (max - min) / 4;
    if (step <= 0) return .{ .lo = min, .hi = max, .step = max - min };
    const mag = @floor(@log10(step));
    const base = std.math.pow(f32, 10.0, mag);
    const norm = step / base;
    const mult: f32 = if (norm < 1.5) 1 else if (norm < 3) 2 else if (norm < 7) 5 else 10;
    step = mult * base;
    const lo = @floor(min / step) * step;
    const hi = @ceil(max / step) * step;
    return .{ .lo = lo, .hi = hi, .step = step };
}

/// Format a tick value: integers plain, fractions with one decimal.
fn fmtNum(arena: std.mem.Allocator, v: f32) []const u8 {
    if (v == 0) return "0";
    if (@abs(v) >= 1) {
        const rounded: f32 = @round(v);
        if (@abs(v - rounded) < 0.001) {
            return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(rounded))}) catch "?";
        }
    }
    return std.fmt.allocPrint(arena, "{d:.1}", .{v}) catch "?";
}

/// Rough text width, so legends size to their content without a measure pass.
fn textWidth(s: []const u8, font_size: f32) f32 {
    return @as(f32, @floatFromInt(s.len)) * font_size * 0.55;
}

fn rect(left: f32, top: f32, width: f32, height: f32) skia.Rect {
    return .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
}

/// The data an `onclick` needs to toggle one legend pill: it must live in
/// node-owned memory (a hook), because clicks fire against the retained tree
/// of the *previous* frame, whose arena is gone by then.
const Toggle = struct {
    state: *anyopaque,
    index: usize,
};

fn makeToggles(st: anytype) void {
    for (&st.toggles, 0..) |*t, i| t.* = .{ .state = @ptrCast(st), .index = i };
}

// ----------------------------------------------------------------------
// Line / area chart
// ----------------------------------------------------------------------

pub const LineSeries = struct {
    name: []const u8 = "",
    values: []const f32,
    color: u32 = 0,
    /// Fill the area between the line and the plot bottom.
    area: bool = false,
    /// Curve the segments (Catmull-Rom).
    smooth: bool = false,
};

pub const LineChartArgs = struct {
    style: element.Style = .{},
    series: []const LineSeries,
    x_labels: []const []const u8 = &.{},
    y_min: ?f32 = null,
    y_max: ?f32 = null,
    show_legend: bool = true,
    key: ?[]const u8 = null,
};

pub fn lineChart(ctx: *context.Context, args: LineChartArgs) element.Element {
    // The series data comes from the caller's frame; copy everything the
    // chart still reads while it is reconciled.
    var series = ctx.arena.alloc(LineSeries, args.series.len) catch
        @panic("zui: out of memory while building the element tree");
    for (args.series, 0..) |s, i| {
        series[i] = .{
            .name = s.name,
            .values = ctx.arena.dupe(f32, s.values) catch
                @panic("zui: out of memory while building the element tree"),
            .color = s.color,
            .area = s.area,
            .smooth = s.smooth,
        };
    }
    return ctx.componentProps("lineChart", LineChart.Props{
        .style = args.style,
        .series = series,
        .x_labels = ctx.arena.dupe([]const u8, args.x_labels) catch
            @panic("zui: out of memory while building the element tree"),
        .y_min = args.y_min,
        .y_max = args.y_max,
        .show_legend = args.show_legend,
        .key = args.key,
    }, LineChart.render);
}

const LineChart = struct {
    const Props = struct {
        style: element.Style,
        series: []const LineSeries,
        x_labels: []const []const u8,
        y_min: ?f32,
        y_max: ?f32,
        show_legend: bool,
        key: ?[]const u8,
    };

    const State = struct {
        host: ?*node_mod.Node = null,
        hover: bool = false,
        hidden: [max_series]bool = falseFlags(),
        toggles: [max_series]Toggle = emptyToggles(),
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        var st = ctx.useState(State, .{});
        st.ptr.host = ctx.node;
        makeToggles(st.ptr);

        const arena = ctx.arena;
        const visible = visibleList(arena, props.series.len, st.ptr.hidden);

        const plot_i: usize = if (props.show_legend and props.series.len > 0) 1 else 0;
        const plot_box = childBox(st.ptr.host, plot_i) orelse rect(0, 0, 320, 200);

        var style = element.Style{
            .direction = .column,
            .flex_grow = 1,
            .background = t.background,
            .border = .all(1),
            .border_color = t.border,
            .border_radius = 10,
            .overflow = .hidden,
        };
        util.applyUser(&style, props.style);

        var children = arena.alloc(element.Element, 2) catch
            @panic("zui: out of memory while building the element tree");
        var n: usize = 0;
        if (props.show_legend and props.series.len > 0) {
            children[n] = legendRow(ctx, props.series, st.ptr);
            n += 1;
        }
        children[n] = cartesianPlot(ctx, props, visible, plot_box, st.ptr);
        n += 1;

        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = children[0..n],
        } };
    }

    /// The shared Cartesian plot (grid, axes, series, hover) for line charts.
    fn cartesianPlot(
        ctx: *context.Context,
        props: Props,
        visible: []const usize,
        box: skia.Rect,
        st: *State,
    ) element.Element {
        const arena = ctx.arena;
        const t = theme.active;
        const count = if (visible.len > 0) props.series[visible[0]].values.len else 0;

        // Union of the visible ranges, expanded to nice boundaries.
        var lo: f32 = std.math.floatMax(f32);
        var hi: f32 = -std.math.floatMax(f32);
        for (visible) |vi| {
            for (props.series[vi].values) |v| {
                lo = @min(lo, v);
                hi = @max(hi, v);
            }
        }
        if (lo > hi) {
            lo = 0;
            hi = 1;
        }
        const scale = niceScale(lo, hi);
        lo = if (props.y_min) |m| m else scale.lo;
        hi = if (props.y_max) |m| m else scale.hi;
        const span = @max(hi - lo, 0.0001);

        const px = pad_left;
        const py = pad_top;
        const pw = @max(box.width() - pad_left - pad_right, 1);
        const ph = @max(box.height() - pad_top - pad_bottom, 1);

        const mapX = struct {
            fn call(b: skia.Rect, i: usize, c: usize) f32 {
                if (c <= 1) return pad_left + (b.width() - pad_left - pad_right) / 2;
                return pad_left + (b.width() - pad_left - pad_right) *
                    (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(c - 1)));
            }
        }.call;
        const mapY = struct {
            fn call(v: f32, ptop: f32, phh: f32, l: f32, s: f32) f32 {
                return ptop + phh * (1 - (v - l) / s);
            }
        }.call;

        var kids: std.ArrayList(element.Element) = .empty;
        kids.ensureTotalCapacity(arena, 32) catch
            @panic("zui: out of memory while building the element tree");

        // ---- grid + y ticks ------------------------------------------------
        var tick: f32 = scale.lo;
        while (tick <= scale.hi + 0.001) : (tick += scale.step) {
            const gy = mapY(tick, py, ph, lo, span);
            kids.append(arena, .{ .rect = .{
                .style = .{
                    .position = .absolute,
                    .left = px,
                    .top = gy,
                    .width = pw,
                    .height = 1,
                    .background = t.border,
                    .flex_shrink = 0,
                },
            } }) catch @panic("zui: out of memory while building the element tree");
            kids.append(arena, .{ .text = .{
                .style = .{
                    .color = t.muted_foreground,
                    .font_size = 11,
                    .left = 4,
                    .top = gy - 7,
                    .position = .absolute,
                },
                .content = fmtNum(arena, tick),
            } }) catch @panic("zui: out of memory while building the element tree");
        }
        if (scale.lo < lo or scale.lo > lo) {} // tick range may exceed the forced y_min/y_max

        // ---- x labels ------------------------------------------------------
        const label_count = @min(count, props.x_labels.len);
        var i: usize = 0;
        while (i < label_count) : (i += 1) {
            const label = props.x_labels[i];
            const lx = mapX(box, i, count) - textWidth(label, 11) / 2;
            kids.append(arena, .{ .text = .{
                .style = .{
                    .color = t.muted_foreground,
                    .font_size = 11,
                    .left = lx,
                    .top = box.height() - 18,
                    .position = .absolute,
                },
                .content = label,
            } }) catch @panic("zui: out of memory while building the element tree");
        }

        // ---- series --------------------------------------------------------
        for (visible) |vi| {
            const s = props.series[vi];
            const color = seriesColor(vi, s.color);
            const pts = arena.alloc(element.Point, s.values.len) catch
                @panic("zui: out of memory while building the element tree");
            for (s.values, 0..) |v, j| pts[j] = .{
                .x = (mapX(box, j, s.values.len) - px) / pw * view,
                .y = (mapY(v, py, ph, lo, span) - py) / ph * view,
            };
            if (s.area) {
                kids.append(arena, .{ .shape = .{
                    .style = .{
                        .background = theme.mix(color, t.background, 0.12),
                        .position = .absolute,
                        .left = px,
                        .top = py,
                        .width = pw,
                        .height = ph,
                    },
                    .ops = areaOps(arena, pts) catch
                        @panic("zui: out of memory while building the element tree"),
                    .fill = true,
                    .view = view,
                } }) catch @panic("zui: out of memory while building the element tree");
            }
            kids.append(arena, .{ .shape = .{
                .style = .{
                    .background = color,
                    .position = .absolute,
                    .left = px,
                    .top = py,
                    .width = pw,
                    .height = ph,
                },
                .ops = if (s.smooth)
                    smoothOps(arena, pts) catch
                        @panic("zui: out of memory while building the element tree")
                else
                    lineOps(arena, pts) catch
                        @panic("zui: out of memory while building the element tree"),
                .fill = false,
                .stroke_width = 2 * view / @max(pw, 1),
                .view = view,
            } }) catch @panic("zui: out of memory while building the element tree");
        }

        // ---- hover: crosshair, dots and the tooltip ------------------------
        var hover_idx: ?usize = null;
        if (st.hover and count > 0) {
            if (ctx.window) |w| {
                const cx = w.cursor_x - box.left;
                if (cx >= px and cx <= px + pw) {
                    const frac = (cx - px) / pw;
                    const idx_f = frac * @as(f32, @floatFromInt(count - 1));
                    hover_idx = @intFromFloat(@max(0, @min(@round(idx_f), @as(f32, @floatFromInt(count - 1)))));
                }
            }
        }
        if (hover_idx) |idx| {
            const hx = mapX(box, idx, count);
            kids.append(arena, .{ .rect = .{
                .style = .{
                    .position = .absolute,
                    .left = hx,
                    .top = py,
                    .width = 1,
                    .height = ph,
                    .background = t.border,
                    .flex_shrink = 0,
                },
            } }) catch @panic("zui: out of memory while building the element tree");
            for (visible) |vi| {
                const s = props.series[vi];
                if (idx >= s.values.len) continue;
                const dot_y = mapY(s.values[idx], py, ph, lo, span);
                kids.append(arena, .{ .rect = .{
                    .style = .{
                        .position = .absolute,
                        .left = hx - 4,
                        .top = dot_y - 4,
                        .width = 8,
                        .height = 8,
                        .border_radius = 4,
                        .background = seriesColor(vi, s.color),
                        .border = .all(2),
                        .border_color = t.background,
                        .flex_shrink = 0,
                    },
                } }) catch @panic("zui: out of memory while building the element tree");
            }
            kids.append(arena, tooltip(ctx, .{
                .x = hx,
                .y = py + ph / 2,
                .anchor_top = py,
                .plot_left = px,
                .plot_right = px + pw,
                .title = xLabel(props.x_labels, idx),
            }, valueRows(ctx, props.series, visible, idx))) catch
                @panic("zui: out of memory while building the element tree");
        }

        // ---- the hit area: transparent, on top ----------------------------
        kids.append(arena, .{ .rect = .{
            .style = .{
                .position = .absolute,
                .left = px,
                .top = py,
                .width = pw,
                .height = ph,
            },
            .onmouseenter = .{ .func = plotEnter, .data = st },
            .onmouseleave = .{ .func = plotLeave, .data = st },
        } }) catch @panic("zui: out of memory while building the element tree");

        return element.Element{ .rect = .{
            .style = .{ .flex_grow = 1, .overflow = .hidden },
            .children = kids.items,
        } };
    }
};

/// The label for category `idx`, or the index when no label was given.
fn xLabel(labels: []const []const u8, idx: usize) []const u8 {
    if (labels.len == 0) return "-";
    return labels[@min(idx, labels.len - 1)];
}

fn plotEnter(p: *anyopaque) void {
    const st: *LineChart.State = @ptrCast(@alignCast(p));
    st.hover = true;
}

fn plotLeave(p: *anyopaque) void {
    const st: *LineChart.State = @ptrCast(@alignCast(p));
    st.hover = false;
}

fn legendToggle(p: *anyopaque) void {
    const tg: *Toggle = @ptrCast(@alignCast(p));
    const st: *LineChart.State = @ptrCast(@alignCast(tg.state));
    if (tg.index < st.hidden.len) st.hidden[tg.index] = !st.hidden[tg.index];
}

/// One "name: value" row per visible series, for the hovered category.
fn valueRows(
    ctx: *context.Context,
    series: []const LineSeries,
    visible: []const usize,
    idx: usize,
) []const element.Element {
    const arena = ctx.arena;
    const t = theme.active;
    var rows: std.ArrayList(element.Element) = .empty;
    rows.ensureTotalCapacity(arena, visible.len) catch
        @panic("zui: out of memory while building the element tree");
    for (visible) |vi| {
        const s = series[vi];
        if (idx >= s.values.len) continue;
        rows.append(arena, .{ .rect = .{
            .style = .{ .direction = .row, .align_items = .center, .gap = 6 },
            .children = util.dupElements(ctx.arena, &.{
                .{ .rect = .{
                    .style = .{
                        .width = 8,
                        .height = 8,
                        .border_radius = 2,
                        .background = seriesColor(vi, s.color),
                        .flex_shrink = 0,
                    },
                } },
                .{ .text = .{
                    .style = .{ .color = t.foreground, .font_size = 12 },
                    .content = std.fmt.allocPrint(arena, "{s}: {s}", .{
                        s.name,
                        fmtNum(arena, s.values[idx]),
                    }) catch "?",
                } },
            }) catch @panic("zui: out of memory while building the element tree"),
        } }) catch @panic("zui: out of memory while building the element tree");
    }
    return rows.items;
}

// ----------------------------------------------------------------------
// Bar chart
// ----------------------------------------------------------------------

pub const BarSeries = struct {
    name: []const u8 = "",
    values: []const f32,
    color: u32 = 0,
};

pub const BarChartArgs = struct {
    style: element.Style = .{},
    series: []const BarSeries,
    x_labels: []const []const u8 = &.{},
    y_min: ?f32 = null,
    y_max: ?f32 = null,
    show_legend: bool = true,
    key: ?[]const u8 = null,
};

pub fn barChart(ctx: *context.Context, args: BarChartArgs) element.Element {
    var series = ctx.arena.alloc(BarSeries, args.series.len) catch
        @panic("zui: out of memory while building the element tree");
    for (args.series, 0..) |s, i| {
        series[i] = .{
            .name = s.name,
            .values = ctx.arena.dupe(f32, s.values) catch
                @panic("zui: out of memory while building the element tree"),
            .color = s.color,
        };
    }
    return ctx.componentProps("barChart", BarChart.Props{
        .style = args.style,
        .series = series,
        .x_labels = ctx.arena.dupe([]const u8, args.x_labels) catch
            @panic("zui: out of memory while building the element tree"),
        .y_min = args.y_min,
        .y_max = args.y_max,
        .show_legend = args.show_legend,
        .key = args.key,
    }, BarChart.render);
}

const BarChart = struct {
    const Props = struct {
        style: element.Style,
        series: []const BarSeries,
        x_labels: []const []const u8,
        y_min: ?f32,
        y_max: ?f32,
        show_legend: bool,
        key: ?[]const u8,
    };

    const State = struct {
        host: ?*node_mod.Node = null,
        hover: bool = false,
        hidden: [max_series]bool = falseFlags(),
        toggles: [max_series]Toggle = emptyToggles(),
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        var st = ctx.useState(State, .{});
        st.ptr.host = ctx.node;
        makeToggles(st.ptr);

        const arena = ctx.arena;
        const visible = visibleList(arena, props.series.len, st.ptr.hidden);

        const plot_i: usize = if (props.show_legend and props.series.len > 0) 1 else 0;
        const box = childBox(st.ptr.host, plot_i) orelse rect(0, 0, 320, 200);

        var lo: f32 = std.math.floatMax(f32);
        var hi: f32 = -std.math.floatMax(f32);
        for (visible) |vi| {
            for (props.series[vi].values) |v| {
                lo = @min(lo, v);
                hi = @max(hi, v);
            }
        }
        if (lo > hi) {
            lo = 0;
            hi = 1;
        }
        const scale = niceScale(lo, hi);
        lo = if (props.y_min) |m| m else scale.lo;
        hi = if (props.y_max) |m| m else scale.hi;
        const span = @max(hi - lo, 0.0001);

        const px = pad_left;
        const py = pad_top;
        const pw = @max(box.width() - pad_left - pad_right, 1);
        const ph = @max(box.height() - pad_top - pad_bottom, 1);

        const count = if (visible.len > 0) props.series[visible[0]].values.len else 0;
        const slot = pw / @max(@as(f32, @floatFromInt(count)), 1);
        const group_w = slot * 0.62;
        const bar_w = group_w / @as(f32, @floatFromInt(@max(visible.len, 1)));

        var kids: std.ArrayList(element.Element) = .empty;
        kids.ensureTotalCapacity(arena, 32) catch
            @panic("zui: out of memory while building the element tree");

        // grid + ticks
        var tick: f32 = scale.lo;
        while (tick <= scale.hi + 0.001) : (tick += scale.step) {
            const gy = py + ph * (1 - (tick - lo) / span);
            kids.append(arena, .{ .rect = .{
                .style = .{
                    .position = .absolute,
                    .left = px,
                    .top = gy,
                    .width = pw,
                    .height = 1,
                    .background = t.border,
                    .flex_shrink = 0,
                },
            } }) catch @panic("zui: out of memory while building the element tree");
            kids.append(arena, .{ .text = .{
                .style = .{
                    .color = t.muted_foreground,
                    .font_size = 11,
                    .left = 4,
                    .top = gy - 7,
                    .position = .absolute,
                },
                .content = fmtNum(arena, tick),
            } }) catch @panic("zui: out of memory while building the element tree");
        }

        // bars
        for (visible, 0..) |vi, k| {
            const s = props.series[vi];
            const color = seriesColor(vi, s.color);
            for (s.values, 0..) |v, j| {
                const bx = px + slot * @as(f32, @floatFromInt(j)) + (slot - group_w) / 2 +
                    bar_w * @as(f32, @floatFromInt(k));
                const y_top = py + ph * (1 - (@max(v, lo) - lo) / span);
                const y_bot = py + ph * (1 - (@min(v, lo) - lo) / span);
                kids.append(arena, .{ .rect = .{
                    .style = .{
                        .position = .absolute,
                        .left = bx,
                        .top = y_top,
                        .width = @max(bar_w - 2, 1),
                        .height = @max(y_bot - y_top, 1),
                        .background = color,
                        .border_radius = 3,
                        .flex_shrink = 0,
                    },
                } }) catch @panic("zui: out of memory while building the element tree");
            }
        }

        // x labels
        const label_count = @min(count, props.x_labels.len);
        var i: usize = 0;
        while (i < label_count) : (i += 1) {
            const label = props.x_labels[i];
            const lx = px + slot * (@as(f32, @floatFromInt(i)) + 0.5) - textWidth(label, 11) / 2;
            kids.append(arena, .{ .text = .{
                .style = .{
                    .color = t.muted_foreground,
                    .font_size = 11,
                    .left = lx,
                    .top = box.height() - 18,
                    .position = .absolute,
                },
                .content = label,
            } }) catch @panic("zui: out of memory while building the element tree");
        }

        // hover: the whole slot is the hit target
        var hover_idx: ?usize = null;
        if (st.ptr.hover and count > 0) {
            if (ctx.window) |w| {
                const cx = w.cursor_x - box.left;
                if (cx >= px and cx <= px + pw) {
                    const idx_f = (cx - px) / slot;
                    hover_idx = @intFromFloat(@max(0, @min(@round(idx_f), @as(f32, @floatFromInt(count - 1)))));
                }
            }
        }
        if (hover_idx) |idx| {
            kids.append(arena, .{ .rect = .{
                .style = .{
                    .position = .absolute,
                    .left = px + slot * @as(f32, @floatFromInt(idx)),
                    .top = py,
                    .width = slot,
                    .height = ph,
                    .background = theme.mix(t.primary, t.background, 0.06),
                },
            } }) catch @panic("zui: out of memory while building the element tree");
            kids.append(arena, tooltip(ctx, .{
                .x = px + slot * (@as(f32, @floatFromInt(idx)) + 0.5),
                .y = py + ph / 2,
                .anchor_top = py,
                .plot_left = px,
                .plot_right = px + pw,
                .title = xLabel(props.x_labels, idx),
            }, barValueRows(ctx, props.series, visible, idx))) catch
                @panic("zui: out of memory while building the element tree");
        }

        kids.append(arena, .{ .rect = .{
            .style = .{
                .position = .absolute,
                .left = px,
                .top = py,
                .width = pw,
                .height = ph,
            },
            .onmouseenter = .{ .func = barEnter, .data = st.ptr },
            .onmouseleave = .{ .func = barLeave, .data = st.ptr },
        } }) catch @panic("zui: out of memory while building the element tree");

        var children = arena.alloc(element.Element, 2) catch
            @panic("zui: out of memory while building the element tree");
        var n: usize = 0;
        if (props.show_legend and props.series.len > 0) {
            children[n] = legendRowBars(ctx, props.series, st.ptr);
            n += 1;
        }
        children[n] = element.Element{ .rect = .{
            .style = .{ .flex_grow = 1, .overflow = .hidden },
            .children = kids.items,
        } };
        n += 1;

        var style = element.Style{
            .direction = .column,
            .flex_grow = 1,
            .background = t.background,
            .border = .all(1),
            .border_color = t.border,
            .border_radius = 10,
            .overflow = .hidden,
        };
        util.applyUser(&style, props.style);
        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = children[0..n],
        } };
    }
};

fn barEnter(p: *anyopaque) void {
    const st: *BarChart.State = @ptrCast(@alignCast(p));
    st.hover = true;
}

fn barLeave(p: *anyopaque) void {
    const st: *BarChart.State = @ptrCast(@alignCast(p));
    st.hover = false;
}

fn barLegendToggle(p: *anyopaque) void {
    const tg: *Toggle = @ptrCast(@alignCast(p));
    const st: *BarChart.State = @ptrCast(@alignCast(tg.state));
    if (tg.index < st.hidden.len) st.hidden[tg.index] = !st.hidden[tg.index];
}

fn barValueRows(
    ctx: *context.Context,
    series: []const BarSeries,
    visible: []const usize,
    idx: usize,
) []const element.Element {
    const arena = ctx.arena;
    const t = theme.active;
    var rows: std.ArrayList(element.Element) = .empty;
    rows.ensureTotalCapacity(arena, visible.len) catch
        @panic("zui: out of memory while building the element tree");
    for (visible) |vi| {
        const s = series[vi];
        if (idx >= s.values.len) continue;
        rows.append(arena, .{ .rect = .{
            .style = .{ .direction = .row, .align_items = .center, .gap = 6 },
            .children = util.dupElements(ctx.arena, &.{
                .{ .rect = .{
                    .style = .{
                        .width = 8,
                        .height = 8,
                        .border_radius = 2,
                        .background = seriesColor(vi, s.color),
                        .flex_shrink = 0,
                    },
                } },
                .{ .text = .{
                    .style = .{ .color = t.foreground, .font_size = 12 },
                    .content = std.fmt.allocPrint(arena, "{s}: {s}", .{
                        s.name,
                        fmtNum(arena, s.values[idx]),
                    }) catch "?",
                } },
            }) catch @panic("zui: out of memory while building the element tree"),
        } }) catch @panic("zui: out of memory while building the element tree");
    }
    return rows.items;
}

// ----------------------------------------------------------------------
// Pie / donut chart
// ----------------------------------------------------------------------

pub const PieSlice = struct {
    name: []const u8 = "",
    value: f32,
    color: u32 = 0,
};

pub const PieChartArgs = struct {
    style: element.Style = .{},
    slices: []const PieSlice,
    /// Inner radius ratio (0 = full pie, 0.6 = donut).
    donut: f32 = 0.6,
    show_legend: bool = true,
    key: ?[]const u8 = null,
};

pub fn pieChart(ctx: *context.Context, args: PieChartArgs) element.Element {
    var slices = ctx.arena.alloc(PieSlice, args.slices.len) catch
        @panic("zui: out of memory while building the element tree");
    for (args.slices, 0..) |s, i| {
        slices[i] = .{ .name = s.name, .value = s.value, .color = s.color };
    }
    return ctx.componentProps("pieChart", PieChart.Props{
        .style = args.style,
        .slices = slices,
        .donut = args.donut,
        .show_legend = args.show_legend,
        .key = args.key,
    }, PieChart.render);
}

const PieChart = struct {
    const Props = struct {
        style: element.Style,
        slices: []const PieSlice,
        donut: f32,
        show_legend: bool,
        key: ?[]const u8,
    };

    const State = struct {
        host: ?*node_mod.Node = null,
        hover: bool = false,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        var st = ctx.useState(State, .{});
        st.ptr.host = ctx.node;
        const arena = ctx.arena;
        const box = childBox(st.ptr.host, 1) orelse rect(0, 0, 200, 220);

        const side = @max(@min(box.width(), box.height()) - 16, 40);
        const cx = box.width() / 2;
        const cy = box.height() / 2;
        const r = side / 2;
        const inner = r * std.math.clamp(props.donut, 0, 0.92);

        var total: f32 = 0;
        for (props.slices) |s| total += @max(s.value, 0);
        if (total <= 0) total = 1;

        // The hovered slice, from the live cursor angle.
        var hover_i: ?usize = null;
        if (st.ptr.hover) {
            if (ctx.window) |w| {
                const dx = w.cursor_x - (box.left + cx);
                const dy = w.cursor_y - (box.top + cy);
                const dist2 = dx * dx + dy * dy;
                if (dist2 <= r * r and dist2 >= inner * inner) {
                    var ang = std.math.atan2(dy, dx) * 180 / std.math.pi;
                    ang = 90 - ang; // 0 degrees at the top, clockwise
                    if (ang < 0) ang += 360;
                    var acc: f32 = 0;
                    for (props.slices, 0..) |s, i| {
                        const sweep = @max(s.value, 0) / total * 360;
                        if (ang >= acc and ang < acc + sweep) {
                            hover_i = i;
                            break;
                        }
                        acc += sweep;
                    }
                }
            }
        }

        var kids: std.ArrayList(element.Element) = .empty;
        kids.ensureTotalCapacity(arena, props.slices.len * 2 + 4) catch
            @panic("zui: out of memory while building the element tree");

        // Slices, each its own shape so each carries its own color.
        var acc: f32 = 0;
        for (props.slices, 0..) |s, i| {
            const sweep = @max(s.value, 0) / total * 360;
            const slice_ops = icons.arcOps(arena, cx, cy, r, acc, sweep) catch
                @panic("zui: out of memory while building the element tree");
            var ops = arena.alloc(element.PathOp, slice_ops.len + 1) catch
                @panic("zui: out of memory while building the element tree");
            @memcpy(ops[0..slice_ops.len], slice_ops);
            ops[slice_ops.len] = .{ .close = {} };
            const dimmed = if (hover_i) |hi| (hi != i) else false;
            kids.append(arena, .{ .shape = .{
                .style = .{
                    .background = if (dimmed)
                        theme.mix(seriesColor(i, s.color), t.background, 0.5)
                    else
                        seriesColor(i, s.color),
                    .position = .absolute,
                    .left = cx - r,
                    .top = cy - r,
                    .width = side,
                    .height = side,
                },
                .ops = ops,
                .fill = true,
                .view = side,
            } }) catch @panic("zui: out of memory while building the element tree");
            acc += sweep;
        }

        // The donut hole, and the center label.
        if (inner > 0.5) {
            kids.append(arena, .{ .shape = .{
                .style = .{
                    .background = props.style.background,
                    .position = .absolute,
                    .left = cx - inner,
                    .top = cy - inner,
                    .width = inner * 2,
                    .height = inner * 2,
                },
                .ops = icons.circleOps(arena, cx, cy, inner) catch
                    @panic("zui: out of memory while building the element tree"),
                .fill = true,
                .view = side,
            } }) catch @panic("zui: out of memory while building the element tree");

            const center_text = if (hover_i) |hi|
                std.fmt.allocPrint(arena, "{s}: {s}", .{
                    props.slices[hi].name,
                    fmtNum(arena, props.slices[hi].value),
                }) catch "?"
            else
                fmtNum(arena, total);
            kids.append(arena, .{ .text = .{
                .style = .{
                    .color = t.foreground,
                    .font_size = if (hover_i == null) 15 else 13,
                    .font_weight = .semibold,
                    .text_align = .center,
                    .left = cx - 60,
                    .top = cy - 14,
                    .width = 120,
                    .position = .absolute,
                },
                .content = center_text,
            } }) catch @panic("zui: out of memory while building the element tree");
        }

        // Percentage labels on slices wide enough to carry one.
        acc = 0;
        for (props.slices, 0..) |s, i| {
            const sweep = @max(s.value, 0) / total * 360;
            const pct = @max(s.value, 0) / total * 100;
            if (sweep >= 18) {
                const mid = (acc + sweep / 2) * std.math.pi / 180;
                const lr = if (inner > 0.5) (r + inner) / 2 else r * 0.62;
                const lx = cx + lr * @sin(mid);
                const ly = cy - lr * @cos(mid);
                kids.append(arena, .{ .text = .{
                    .style = .{
                        .color = 0xFFFFFFFF,
                        .font_size = 11,
                        .font_weight = .medium,
                        .text_align = .center,
                        .left = lx - 24,
                        .top = ly - 7,
                        .width = 48,
                        .position = .absolute,
                    },
                    .content = std.fmt.allocPrint(arena, "{d:.0}%", .{pct}) catch "?",
                } }) catch @panic("zui: out of memory while building the element tree");
            }
            acc += sweep;
            _ = i;
        }

        // Hover tooltip placed just outside the slice's mid angle.
        if (hover_i) |hi| {
            const s = props.slices[hi];
            const mid_ang = (startAngle(props.slices, hi) +
                @max(s.value, 0) / total * 360 / 2) * std.math.pi / 180;
            const tx = cx + (r + 8) * @sin(mid_ang);
            const ty = cy - (r + 8) * @cos(mid_ang);
            kids.append(arena, tooltip(ctx, .{
                .x = tx,
                .y = ty,
                .anchor_top = 4,
                .plot_left = 4,
                .plot_right = @max(box.width() - 4, 8),
                .title = s.name,
            }, pieRows(ctx, s, @max(s.value, 0) / total * 100))) catch
                @panic("zui: out of memory while building the element tree");
        }

        // The hit area: the pie circle, transparent, on top.
        kids.append(arena, .{ .rect = .{
            .style = .{
                .position = .absolute,
                .left = cx - r,
                .top = cy - r,
                .width = side,
                .height = side,
                .border_radius = r,
                .overflow = .hidden,
            },
            .onmouseenter = .{ .func = pieEnter, .data = st.ptr },
            .onmouseleave = .{ .func = pieLeave, .data = st.ptr },
        } }) catch @panic("zui: out of memory while building the element tree");

        var children = arena.alloc(element.Element, 2) catch
            @panic("zui: out of memory while building the element tree");
        var n: usize = 0;
        if (props.show_legend and props.slices.len > 0) {
            children[n] = pieLegendRow(ctx, props.slices);
            n += 1;
        }
        children[n] = element.Element{ .rect = .{
            .style = .{ .flex_grow = 1, .overflow = .hidden },
            .children = kids.items,
        } };
        n += 1;

        var style = element.Style{
            .direction = .column,
            .flex_grow = 1,
            .background = t.background,
            .border = .all(1),
            .border_color = t.border,
            .border_radius = 10,
            .overflow = .hidden,
        };
        util.applyUser(&style, props.style);
        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = children[0..n],
        } };
    }
};

fn pieEnter(p: *anyopaque) void {
    const st: *PieChart.State = @ptrCast(@alignCast(p));
    st.hover = true;
}

fn pieLeave(p: *anyopaque) void {
    const st: *PieChart.State = @ptrCast(@alignCast(p));
    st.hover = false;
}

fn pieRows(ctx: *context.Context, s: PieSlice, pct: f32) []const element.Element {
    const arena = ctx.arena;
    const t = theme.active;
    const value_text = std.fmt.allocPrint(arena, "{s} ({d:.1}%)", .{
        fmtNum(arena, s.value),
        pct,
    }) catch "?";
    return util.dupElements(ctx.arena, &.{.{ .text = .{
        .style = .{ .color = t.foreground, .font_size = 12 },
        .content = value_text,
    } }}) catch @panic("zui: out of memory while building the element tree");
}

/// The cumulative angle (degrees) at the start of slice `i`.
fn startAngle(slices: []const PieSlice, upto: usize) f32 {
    var total: f32 = 0;
    for (slices) |s| total += @max(s.value, 0);
    if (total <= 0) total = 1;
    var acc: f32 = 0;
    for (slices[0..@min(upto, slices.len)]) |s| {
        acc += @max(s.value, 0) / total * 360;
    }
    return acc;
}

// ----------------------------------------------------------------------
// Shared pieces: legends, tooltip, series paths
// ----------------------------------------------------------------------

/// Indices of the series still shown; a legend toggle above `max_series`
/// is ignored (always visible).
fn visibleList(arena: std.mem.Allocator, len: usize, hidden: [max_series]bool) []const usize {
    var list: std.ArrayList(usize) = .empty;
    list.ensureTotalCapacity(arena, len) catch
        @panic("zui: out of memory while building the element tree");
    for (0..len) |i| {
        if (i < hidden.len and hidden[i]) continue;
        list.append(arena, i) catch
            @panic("zui: out of memory while building the element tree");
    }
    return list.items;
}

fn legendRow(ctx: *context.Context, series: []const LineSeries, st: *LineChart.State) element.Element {
    const t = theme.active;
    var pills = ctx.arena.alloc(element.Element, series.len) catch
        @panic("zui: out of memory while building the element tree");
    for (series, 0..) |s, i| {
        const off = i < st.hidden.len and st.hidden[i];
        pills[i] = .{ .rect = .{
            .style = .{
                .direction = .row,
                .align_items = .center,
                .gap = 6,
                .padding = .{ .left = 8, .right = 10, .top = 4, .bottom = 4 },
                .border_radius = 12,
                .background = if (off) t.muted else 0,
                .flex_shrink = 0,
                .border = .all(1),
                .border_color = t.border,
            },
            .children = util.dupElements(ctx.arena, &.{
                .{ .rect = .{
                    .style = .{
                        .width = 8,
                        .height = 8,
                        .border_radius = 2,
                        .background = if (off)
                            theme.mix(seriesColor(i, s.color), t.background, 0.65)
                        else
                            seriesColor(i, s.color),
                        .flex_shrink = 0,
                    },
                } },
                .{ .text = .{
                    .style = .{
                        .color = if (off) t.muted_foreground else t.foreground,
                        .font_size = 12,
                    },
                    .content = s.name,
                } },
            }) catch @panic("zui: out of memory while building the element tree"),
            .onclick = .{ .func = legendToggle, .data = &st.toggles[i] },
            .cursor = .hand,
        } };
    }
    return element.Element{ .rect = .{
        .style = .{
            .direction = .row,
            .gap = 8,
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 0 },
            .flex_shrink = 0,
        },
        .children = pills,
    } };
}

fn legendRowBars(ctx: *context.Context, series: []const BarSeries, st: *BarChart.State) element.Element {
    const t = theme.active;
    var pills = ctx.arena.alloc(element.Element, series.len) catch
        @panic("zui: out of memory while building the element tree");
    for (series, 0..) |s, i| {
        const off = i < st.hidden.len and st.hidden[i];
        pills[i] = .{ .rect = .{
            .style = .{
                .direction = .row,
                .align_items = .center,
                .gap = 6,
                .padding = .{ .left = 8, .right = 10, .top = 4, .bottom = 4 },
                .border_radius = 12,
                .background = if (off) t.muted else 0,
                .flex_shrink = 0,
                .border = .all(1),
                .border_color = t.border,
            },
            .children = util.dupElements(ctx.arena, &.{
                .{ .rect = .{
                    .style = .{
                        .width = 8,
                        .height = 8,
                        .border_radius = 2,
                        .background = if (off)
                            theme.mix(seriesColor(i, s.color), t.background, 0.65)
                        else
                            seriesColor(i, s.color),
                        .flex_shrink = 0,
                    },
                } },
                .{ .text = .{
                    .style = .{
                        .color = if (off) t.muted_foreground else t.foreground,
                        .font_size = 12,
                    },
                    .content = s.name,
                } },
            }) catch @panic("zui: out of memory while building the element tree"),
            .onclick = .{ .func = barLegendToggle, .data = &st.toggles[i] },
            .cursor = .hand,
        } };
    }
    return element.Element{ .rect = .{
        .style = .{
            .direction = .row,
            .gap = 8,
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 0 },
            .flex_shrink = 0,
        },
        .children = pills,
    } };
}

fn pieLegendRow(ctx: *context.Context, slices: []const PieSlice) element.Element {
    const t = theme.active;
    var pills = ctx.arena.alloc(element.Element, slices.len) catch
        @panic("zui: out of memory while building the element tree");
    for (slices, 0..) |s, i| {
        pills[i] = .{ .rect = .{
            .style = .{
                .direction = .row,
                .align_items = .center,
                .gap = 6,
                .padding = .{ .left = 8, .right = 10, .top = 4, .bottom = 4 },
                .border_radius = 12,
                .flex_shrink = 0,
                .border = .all(1),
                .border_color = t.border,
            },
            .children = util.dupElements(ctx.arena, &.{
                .{ .rect = .{
                    .style = .{
                        .width = 8,
                        .height = 8,
                        .border_radius = 2,
                        .background = seriesColor(i, s.color),
                        .flex_shrink = 0,
                    },
                } },
                .{ .text = .{
                    .style = .{ .color = t.foreground, .font_size = 12 },
                    .content = s.name,
                } },
            }) catch @panic("zui: out of memory while building the element tree"),
        } };
    }
    return element.Element{ .rect = .{
        .style = .{
            .direction = .row,
            .gap = 8,
            .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
            .flex_shrink = 0,
        },
        .children = pills,
    } };
}

const TooltipArgs = struct {
    /// Anchor point, in plot-relative coordinates.
    x: f32,
    y: f32,
    /// The pill stays within (`plot_left` .. `plot_right`), above `anchor_top`.
    anchor_top: f32,
    plot_left: f32,
    plot_right: f32,
    title: []const u8,
};

/// The floating value list: absolutely positioned, painted last so it sits
/// above the series.
fn tooltip(ctx: *context.Context, args: TooltipArgs, rows: []const element.Element) element.Element {
    const t = theme.active;
    const w: f32 = 148;
    const row_h: f32 = 20;
    const h: f32 = 30 + row_h * @as(f32, @floatFromInt(rows.len));

    // Clamp horizontally inside the plot; vertically flip above the anchor
    // when there is room (ECharts does the same).
    const left = @max(@min(args.x - w / 2, args.plot_right - w - 4), args.plot_left + 4);
    const top = @max(args.anchor_top + 4, args.y - h - 12);

    var kids = ctx.arena.alloc(element.Element, rows.len + 1) catch
        @panic("zui: out of memory while building the element tree");
    kids[0] = .{ .text = .{
        .style = .{ .color = t.muted_foreground, .font_size = 11, .font_weight = .semibold },
        .content = args.title,
    } };
    for (rows, 0..) |r, i| kids[i + 1] = r;

    return element.Element{ .rect = .{
        .style = .{
            .position = .absolute,
            .left = left,
            .top = top,
            .width = w,
            .height = h,
            .background = t.surface,
            .border = .all(1),
            .border_color = t.border,
            .border_radius = 6,
            .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 8 },
            .direction = .column,
            .gap = 2,
            .flex_shrink = 0,
        },
        .children = kids,
    } };
}

/// Polyline through `pts` (already in `view` space).
fn lineOps(arena: std.mem.Allocator, pts: []const element.Point) ![]element.PathOp {
    if (pts.len == 0) return &.{};
    var ops = try arena.alloc(element.PathOp, pts.len);
    ops[0] = .{ .move_to = pts[0] };
    for (pts[1..], 1..) |p, i| ops[i] = .{ .line_to = p };
    return ops;
}

/// The filled area under a polyline, down to the plot bottom (`view` high).
fn areaOps(arena: std.mem.Allocator, pts: []const element.Point) ![]element.PathOp {
    if (pts.len == 0) return &.{};
    var ops = try arena.alloc(element.PathOp, pts.len + 3);
    ops[0] = .{ .move_to = .{ .x = pts[0].x, .y = view } };
    ops[1] = .{ .line_to = pts[0] };
    for (pts[1..], 2..) |p, i| ops[i] = .{ .line_to = p };
    ops[pts.len + 1] = .{ .line_to = .{ .x = pts[pts.len - 1].x, .y = view } };
    ops[pts.len + 2] = .{ .close = {} };
    return ops;
}

/// Catmull-Rom (uniform) through the points, as cubic segments.
fn smoothOps(arena: std.mem.Allocator, pts: []const element.Point) ![]element.PathOp {
    if (pts.len < 3) return lineOps(arena, pts);
    var ops = try arena.alloc(element.PathOp, pts.len);
    ops[0] = .{ .move_to = pts[0] };
    for (pts[1..], 1..) |pi, i| {
        const p0 = if (i >= 2) pts[i - 2] else pts[i - 1];
        const p1 = pts[i - 1];
        const p2 = pi;
        const p3 = if (i + 1 < pts.len) pts[i + 1] else pi;
        ops[i] = .{ .cubic_to = .{
            .c1 = .{ .x = p1.x + (p2.x - p0.x) / 6, .y = p1.y + (p2.y - p0.y) / 6 },
            .c2 = .{ .x = p2.x - (p3.x - p1.x) / 6, .y = p2.y - (p3.y - p1.y) / 6 },
            .p = p2,
        } };
    }
    return ops;
}
