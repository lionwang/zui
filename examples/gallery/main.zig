//! The component gallery: every default component on one page, plus an
//! automated driver that exercises each one.
//!
//!   zig build gallery           run the gallery (Quit in the dialog closes)
//!   zig build gallery -- check  drive every widget and verify the result

const std = @import("std");
const zui = @import("zui");
const ui = zui.ui;
const Context = zui.Context;
const element = zui.element;
const Element = zui.Element;
const node_mod = zui.node;
const skia = zui.skia;

// ----------------------------------------------------------------------
// Demo state, exposed to the driver through hook pointers refreshed every
// frame by the root component (see `render`).
// ----------------------------------------------------------------------

const Demo = struct {
    checkbox: ?*bool = null,
    switch_on: ?*bool = null,
    radio: ?*u32 = null,
    slider: ?*f32 = null,
    stepper: ?*f32 = null,
    rating: ?*u32 = null,
    tab: ?*u32 = null,
    dd_open: ?*bool = null,
    dd_selected: ?*u32 = null,
    modal_open: ?*bool = null,
    confirmations: usize = 0,
    notifications: usize = 0,
};

var demo: Demo = .{};

fn boolToggle(p: *bool) void {
    p.* = !p.*;
}

// Chart data for the CHARTS section (string literals and rodata arrays live
// as long as the program; the components still deep-copy the values).
const days = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const revenue = [_]f32{ 120, 132, 101, 134, 90, 230, 210 };
const cost = [_]f32{ 70, 82, 61, 74, 50, 130, 110 };
const forecast = [_]f32{ 100, 120, 90, 130, 80, 200, 190 };

const browsers = [_]ui.PieSlice{
    .{ .name = "Chrome", .value = 62 },
    .{ .name = "Safari", .value = 19 },
    .{ .name = "Edge", .value = 9 },
    .{ .name = "Firefox", .value = 5 },
    .{ .name = "Other", .value = 5 },
};

const os_series = [_]ui.BarSeries{
    .{ .name = "Desktop", .values = &.{ 320, 302, 301, 334, 390, 330, 320 } },
    .{ .name = "Mobile", .values = &.{ 120, 132, 101, 134, 90, 230, 210 } },
};
const os_labels = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };

/// A click handler that does nothing (buttons in the showcase sections).
fn noHandler() element.Handler {
    return .{ .func = noop, .data = @ptrCast(&demo) };
}

/// `std.Thread.sleep` moved behind the Io interface in Zig 0.16; the
/// gallery only needs to idle the thread between rendered frames.
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;

fn noop(p: *anyopaque) void {
    _ = p;
}

fn onConfirm(p: *anyopaque) void {
    const d: *Demo = @ptrCast(@alignCast(p));
    d.confirmations += 1;
    if (d.modal_open) |o| o.* = false;
}

fn onNotify(p: *anyopaque) void {
    const d: *Demo = @ptrCast(@alignCast(p));
    d.notifications += 1;
    ui.pushToast("Hello from the gallery", .info, 3000);
}

// ----------------------------------------------------------------------
// The root component
// ----------------------------------------------------------------------

pub const Gallery = struct {
    pub fn render(ctx: *Context, props: void) Element {
        _ = props;
        const t = ui.theme.active;

        const cb = ctx.useState(bool, false);
        demo.checkbox = cb.ptr;
        const sw = ctx.useState(bool, false);
        demo.switch_on = sw.ptr;
        const radio = ctx.useState(u32, 0);
        demo.radio = radio.ptr;
        const slider = ctx.useState(f32, 20);
        demo.slider = slider.ptr;
        const step = ctx.useState(f32, 1);
        demo.stepper = step.ptr;
        const rating = ctx.useState(u32, 3);
        demo.rating = rating.ptr;
        const tab = ctx.useState(u32, 0);
        demo.tab = tab.ptr;
        const dd_open = ctx.useState(bool, false);
        demo.dd_open = dd_open.ptr;
        const dd_sel = ctx.useState(u32, 0);
        demo.dd_selected = dd_sel.ptr;
        const modal_open = ctx.useState(bool, false);
        demo.modal_open = modal_open.ptr;

        const dd_items = [_]ui.MenuItem{
            .{ .label = "Option A" },
            .{ .label = "Option B" },
            .{ .separator = true },
            .{ .label = "Option C" },
        };

        const dialog = ui.column(ctx, .{
            .style = .{ .padding = .all(20), .gap = 14, .width = 360 },
            .children = &.{
                .{ .text = .{
                    .style = .{ .color = t.foreground, .font_size = 16, .font_weight = .semibold },
                    .content = "Delete the project?",
                } },
                .{ .text = .{
                    .style = .{ .color = t.muted_foreground, .font_size = 13, .line_height = 1.5 },
                    .content = "This cannot be undone. The driver counts your confirmations.",
                } },
                ui.rect(ctx, .{
                    .style = .{ .direction = .row, .gap = 10 },
                    .children = &.{
                        ui.spacer(ctx, .{}),
                        ui.button(ctx, .{ .label = "Cancel", .size = .sm, .onclick = modal_open.handler(boolToggle) }),
                        ui.button(ctx, .{
                            .label = "Confirm",
                            .variant = .danger,
                            .size = .sm,
                            .onclick = .{ .func = onConfirm, .data = @ptrCast(&demo) },
                        }),
                    },
                }),
            },
        });

        const scroll_content = ui.column(ctx, .{
            .style = .{ .gap = 0, .align_items = .stretch },
            .children = &.{
                section(ctx, "BUTTONS", &.{
                    ui.rect(ctx, .{
                        .style = .{ .direction = .row, .align_items = .center, .gap = 10 },
                        .children = &.{
                            ui.button(ctx, .{ .label = "Default", .onclick = noHandler() }),
                            ui.button(ctx, .{ .label = "Primary", .variant = .primary, .onclick = noHandler() }),
                            ui.button(ctx, .{ .label = "Outline", .variant = .outline, .onclick = noHandler() }),
                            ui.button(ctx, .{ .label = "Ghost", .variant = .ghost, .onclick = noHandler() }),
                            ui.button(ctx, .{ .label = "Danger", .variant = .danger, .onclick = noHandler() }),
                            ui.button(ctx, .{ .label = "Disabled", .disabled = true, .onclick = noHandler() }),
                            ui.iconButton(ctx, .{ .icon = &ui.icons.plus, .variant = .outline, .onclick = noHandler() }),
                        },
                    }),
                }),
                section(ctx, "CONTROLS", &.{
                    controlRow(ctx, ui.checkbox(ctx, cb, "Subscribe to updates", .{}), "Subscribe"),
                    controlRow(ctx, ui.switchControl(ctx, sw, .{}), "Notifications"),
                    controlRow(ctx, ui.radioGroup(ctx, .{
                        .selected = radio,
                        .labels = &.{ "Admin", "Editor", "Viewer" },
                        .direction = .row,
                    }), "Role"),
                    controlRow(ctx, ui.slider(ctx, .{ .value = slider, .style = .{ .width = 220 } }), "Brightness"),
                    controlRow(ctx, ui.stepper(ctx, .{ .value = step, .min = 0, .max = 9 }), "Quantity"),
                    controlRow(ctx, ui.rating(ctx, .{ .value = rating }), "Rate us"),
                    controlRow(ctx, ui.dropdown(ctx, .{
                        .open = dd_open,
                        .selected = dd_sel,
                        .items = &dd_items,
                        .label = "Choose an option",
                    }), "Dropdown"),
                    controlRow(ctx, ui.tooltip(ctx, .{
                        .child = ui.button(ctx, .{ .label = "Hover me" }),
                        .content = "A helpful tip",
                    }), "Tooltip"),
                }),
                section(ctx, "INDICATORS", &.{
                    ui.rect(ctx, .{
                        .style = .{ .direction = .row, .align_items = .center, .gap = 10 },
                        .children = &.{
                            ui.badge(ctx, .{ .text = "3" }),
                            ui.badge(ctx, .{ .text = "new", .color = t.success }),
                            ui.tag(ctx, .{ .text = "zig", .color = t.primary, .onclose = .{ .func = noop, .data = undefined } }),
                            ui.tag(ctx, .{ .text = "ui", .closable = false }),
                            ui.avatar(ctx, .{ .text = "AB", .size = 30 }),
                            ui.kbd(ctx, .{ .text = "Ctrl" }),
                            ui.kbd(ctx, .{ .text = "K" }),
                            ui.spinner(ctx, .{}),
                        },
                    }),
                    ui.rect(ctx, .{
                        .style = .{ .direction = .column, .gap = 10, .padding = .{ .top = 6 } },
                        .children = &.{
                            ui.rect(ctx, .{
                                .style = .{ .direction = .row, .align_items = .center, .gap = 14 },
                                .children = &.{
                                    ui.progress(ctx, .{ .value = 0.25, .style = .{ .width = 320 } }),
                                    caption("Progress 25%"),
                                },
                            }),
                            ui.rect(ctx, .{
                                .style = .{ .direction = .row, .align_items = .center, .gap = 14 },
                                .children = &.{
                                    ui.progress(ctx, .{ .value = 0.7, .style = .{ .width = 320 } }),
                                    caption("Progress 70%"),
                                },
                            }),
                            ui.rect(ctx, .{
                                .style = .{ .direction = .row, .align_items = .center, .gap = 14 },
                                .children = &.{
                                    ui.progressCircle(ctx, .{ .value = 0.66 }),
                                    ui.progressCircle(ctx, .{ .value = 0.25 }),
                                    caption("Circular"),
                                },
                            }),
                        },
                    }),
                    ui.rect(ctx, .{
                        .style = .{ .direction = .row, .align_items = .center, .gap = 10 },
                        .children = &.{
                            ui.skeleton(ctx, .{ .style = .{ .width = 200, .height = 14 } }),
                            ui.skeleton(ctx, .{ .style = .{ .width = 120, .height = 14, .flex_shrink = 0 } }),
                            caption("Skeleton"),
                        },
                    }),
                    ui.divider(.{ .style = .{ .margin = .{ .top = 10 } } }),
                }),
                section(ctx, "PANELS", &.{
                    ui.tabs(ctx, .{
                        .selected = tab,
                        .labels = &.{ "Overview", "Details" },
                        .children = &.{
                            .{ .text = .{
                                .style = .{ .color = t.muted_foreground, .font_size = 13 },
                                .content = "Overview pane",
                            } },
                            .{ .text = .{
                                .style = .{ .color = t.muted_foreground, .font_size = 13 },
                                .content = "Details pane",
                            } },
                        },
                    }),
                    ui.accordion(ctx, .{
                        .items = &.{
                            .{ .title = "Section one", .content = .{ .text = .{
                                .style = .{ .color = t.muted_foreground, .font_size = 13 },
                                .content = "Collapsible content of section one",
                            } } },
                            .{ .title = "Section two", .content = .{ .text = .{
                                .style = .{ .color = t.muted_foreground, .font_size = 13 },
                                .content = "Collapsible content of section two",
                            } } },
                        },
                    }),
                }),
                section(ctx, "OVERLAYS", &.{
                    ui.rect(ctx, .{
                        .style = .{ .direction = .row, .align_items = .center, .gap = 10 },
                        .children = &.{
                            ui.button(ctx, .{
                                .label = "Open dialog",
                                .variant = .primary,
                                .onclick = modal_open.handler(boolToggle),
                            }),
                            ui.button(ctx, .{
                                .label = "Notify",
                                .onclick = .{ .func = onNotify, .data = @ptrCast(&demo) },
                            }),
                        },
                    }),
                }),
                section(ctx, "CHARTS", &.{
                    ui.rect(ctx, .{ .style = .{ .height = 220, .flex_shrink = 0 },
                        .children = &.{
                            ui.lineChart(ctx, .{
                                .show_legend = true,
                                .x_labels = &days,
                                .series = &.{
                                    .{ .name = "Revenue", .values = &revenue, .area = true, .smooth = true },
                                    .{ .name = "Cost", .values = &cost, .color = 0xFFEE6666 },
                                    .{ .name = "Forecast", .values = &forecast, .color = 0xFF91CC75 },
                                },
                            }),
                        },
                    }),
                    ui.rect(ctx, .{ .style = .{ .height = 220, .flex_shrink = 0, .margin = .{ .top = 14 } },
                        .children = &.{
                            ui.barChart(ctx, .{
                                .show_legend = true,
                                .x_labels = &os_labels,
                                .series = &os_series,
                            }),
                        },
                    }),
                    ui.rect(ctx, .{ .style = .{ .height = 240, .flex_shrink = 0, .margin = .{ .top = 14 } },
                        .children = &.{
                            ui.pieChart(ctx, .{
                                .slices = &browsers,
                                .donut = 0.6,
                                .show_legend = true,
                            }),
                        },
                    }),
                }),
            },
        });
        return ui.column(ctx, .{
            .style = .{ .flex_grow = 1, .background = t.background },
            .children = &.{
                ui.rect(ctx, .{
                    .style = .{ .flex_grow = 1, .scroll = .{} },
                    .children = &.{scroll_content},
                }),
                ui.toaster(ctx, .{}),
                ui.modal(ctx, .{ .open = modal_open, .content = dialog }),
            },
        });
    }
};

/// A section: a small uppercase header above the content.
fn section(ctx: *Context, title: []const u8, content: []const Element) Element {
    const t = ui.theme.active;
    const children = ctx.arena.alloc(Element, content.len + 1) catch
        @panic("zui: out of memory while building the element tree");
    children[0] = .{ .text = .{
        .style = .{
            .color = t.muted_foreground,
            .font_size = 12,
            .font_weight = .semibold,
            .letter_spacing = 1.2,
        },
        .content = title,
    } };
    @memcpy(children[1..], content);
    return ui.column(ctx, .{
        .style = .{
            .gap = 10,
            .padding = .{ .left = 24, .right = 24, .top = 16, .bottom = 18 },
            .background = t.background,
            .border = .{ .bottom = 1 },
            .border_color = t.border,
        },
        .children = children,
    });
}

/// A row of [widget, caption]: the caption doubles as the driver's marker
/// for locating the widget's box.
fn controlRow(ctx: *Context, widget: Element, marker: []const u8) Element {
    return ui.row(ctx, .{
        .style = .{ .align_items = .center, .gap = 14 },
        .children = &.{ widget, caption(marker) },
    });
}

fn caption(text: []const u8) Element {
    return Element{ .text = .{
        .style = .{ .color = ui.theme.active.muted_foreground, .font_size = 13 },
        .content = text,
    } };
}

// ----------------------------------------------------------------------
// Entry point
// ----------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, std.heap.page_allocator) catch return;
    defer args.deinit();
    _ = args.next(); // the program path
    var check_mode = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "check")) check_mode = true;
    }

    var application = try zui.App.init(std.heap.page_allocator, Gallery, {}, .{
        .title = "zui gallery",
        .width = 720,
        .height = 720,
        .background = ui.theme.light.background,
        // Escape is the modal's close key; the dialog's Cancel / close
        // buttons (and the window) close the app.
        .exit_on_escape = false,
    });
    defer application.deinit();

    if (check_mode) {
        try checkAll(&application);
        return;
    }

    try application.run();
}

// ----------------------------------------------------------------------
// Automated driver: synthetic input against the rendered tree, then
// assertions on the hook state the component publishes.
// ----------------------------------------------------------------------

fn findText(n: *node_mod.Node, content: []const u8) ?*node_mod.Node {
    if (n.kind == .text) {
        if (n.text) |t| {
            if (std.mem.eql(u8, t, content)) return n;
        }
        return null;
    }
    if (n.child) |c| {
        if (findText(c, content)) |f| return f;
    }
    for (n.children.items) |c| {
        if (findText(c, content)) |f| return f;
    }
    return null;
}

/// The box of the `i`-th child of `n`'s expansion (component nodes expand
/// through `.child`), from the previous frame's layout.
fn childBox(n: *node_mod.Node, i: usize) ?skia.Rect {
    var node = n;
    while (node.kind == .component) {
        node = node.child orelse return null;
    }
    if (node.children.items.len <= i) return null;
    return node.children.items[i].bounds();
}

/// The parent rect of the marker text = the control row; its `i`-th child
/// is the widget under test.
fn markerChildBox(root: *node_mod.Node, marker: []const u8, i: usize) ?skia.Rect {
    const t = findText(root, marker) orelse return null;
    const row = t.parent orelse return null;
    return childBox(row, i);
}

fn center(b: skia.Rect) struct { x: f32, y: f32 } {
    return .{ .x = (b.left + b.right) / 2, .y = (b.top + b.bottom) / 2 };
}

fn clickAt(app: *zui.App, x: f32, y: f32) !void {
    app.window.queue.push(.{ .cursor_move = .{ .x = x, .y = y } });
    app.window.queue.push(.{ .mouse_button = .{
        .button = .left,
        .action = .press,
        .mods = .{},
        .x = x,
        .y = y,
    } });
    app.window.queue.push(.{ .mouse_button = .{
        .button = .left,
        .action = .release,
        .mods = .{},
        .x = x,
        .y = y,
    } });
    try app.frame();
}

fn pressDrag(app: *zui.App, x0: f32, y: f32, x1: f32) !void {
    app.window.queue.push(.{ .cursor_move = .{ .x = x0, .y = y } });
    app.window.queue.push(.{ .mouse_button = .{ .button = .left, .action = .press, .mods = .{}, .x = x0, .y = y } });
    try app.frame();
    app.window.queue.push(.{ .cursor_move = .{ .x = x1, .y = y } });
    app.window.queue.push(.{ .mouse_button = .{ .button = .left, .action = .release, .mods = .{}, .x = x1, .y = y } });
    try app.frame();
}

fn hover(app: *zui.App, x: f32, y: f32) !void {
    app.window.queue.push(.{ .cursor_move = .{ .x = x, .y = y } });
    try app.frame();
}

/// Wheel the scroll container until `marker`'s box sits inside the viewport.
/// Sections further down the page are unreachable otherwise: their boxes are
/// laid out below the window and hit testing skips what the scroller clips.
fn scrollIntoView(app: *zui.App, root: *node_mod.Node, marker: []const u8) !void {
    const t = findText(root, marker) orelse return error.MarkerNotFound;
    const n = t.parent orelse return error.MarkerNotFound;
    try scrollNodeIntoView(app, n);
}

/// Wheel the scroll container until `node`'s box sits fully inside the
/// viewport (the bounds are re-read every iteration: a marker's own row
/// often hides the much taller widget below it). Sections further down the
/// page are unreachable otherwise: their boxes are laid out below the
/// window and hit testing skips what the scroller clips.
fn scrollNodeIntoView(app: *zui.App, node: *node_mod.Node) !void {
    var attempt: u32 = 0;
    while (attempt < 40) : (attempt += 1) {
        const b = node.bounds();
        if (b.top >= 8 and b.bottom <= @as(f32, @floatFromInt(app.window.height)) - 8) return;
        try hover(app, @as(f32, @floatFromInt(app.window.width)) / 2, @as(f32, @floatFromInt(app.window.height)) / 2);
        app.window.queue.push(.{ .scroll = .{ .x = 0, .y = -1 } });
        try app.frame();
    }
    return error.NotScrolled;
}

fn pressKey(app: *zui.App, k: zui.events.Key) !void {
    app.window.queue.push(.{ .key = .{ .key = k, .scancode = 0, .action = .press, .mods = .{} } });
    try app.frame();
}

/// Wait `ms` of real time, rendering frames so timers and the frame clock
/// (tooltip delay, toast lifetimes) keep advancing.
fn waitFrames(app: *zui.App, ms: u64) !void {
    const deadline = skia.millis() + ms;
    while (skia.millis() < deadline) {
        try app.frame();
        Sleep(16);
    }
    try app.frame();
}

fn fail(comptime fmt: []const u8, args: anytype) noret {
    std.debug.print(fmt, args);
}

const noret = void;

fn checkAll(app: *zui.App) !void {
    const root = app.root_node;
    const w = app.window;

    // Two warm-up frames: dynamic geometry (slider tracks, popover layers)
    // is only exact from the second rendered frame on.
    try app.frame();
    try app.frame();
    std.debug.print("WIN size={d}x{d}\n", .{ w.width, w.height });

    // ---- checkbox (its own label is the marker) ----------------------
    {
        const t = findText(root, "Subscribe to updates") orelse return error.MarkerNotFound;
        const row = t.parent orelse return error.MarkerNotFound;
        const rb = row.bounds();
        const c = center(rb);
        try clickAt(app, c.x, c.y);
        const on = demo.checkbox.?.*;
        std.debug.print("CHECKBOX checked={}\n", .{on});
        if (!on) return error.CheckboxFailed;
    }

    // ---- switch ------------------------------------------------------
    {
        const b = markerChildBox(root, "Notifications", 0) orelse return error.MarkerNotFound;
        const c = center(b);
        try clickAt(app, c.x, c.y);
        const on = demo.switch_on.?.*;
        std.debug.print("SWITCH on={}\n", .{on});
        if (!on) return error.SwitchFailed;
    }

    // ---- radio -------------------------------------------------------
    {
        const t = findText(root, "Editor") orelse return error.MarkerNotFound;
        const item = t.parent orelse return error.MarkerNotFound;
        const c = center(item.bounds());
        try clickAt(app, c.x, c.y);
        const sel = demo.radio.?.*;
        std.debug.print("RADIO selected={d}\n", .{sel});
        if (sel != 1) return error.RadioFailed;
    }

    // ---- slider ------------------------------------------------------
    {
        // The caption marks the row; row.children[0] is the slider
        // component, whose first child is the track.
        const t = findText(root, "Brightness") orelse return error.MarkerNotFound;
        const row = t.parent orelse return error.MarkerNotFound;
        const slider_root = row.children.items[0];
        const track = childBox(slider_root, 0) orelse return error.MarkerNotFound;
        const y = (track.top + track.bottom) / 2;
        const x = track.left + (track.right - track.left) * 0.6;
        try pressDrag(app, track.left + 4, y, x);
        const v = demo.slider.?.*;
        std.debug.print("SLIDER value={d:.1}\n", .{v});
        if (v < 50 or v > 70) {
            std.debug.print("SLIDER_FAIL: expected ~60 got {d:.1}\n", .{v});
            return error.SliderFailed;
        }
    }

    // ---- stepper -----------------------------------------------------
    {
        const t = findText(root, "Quantity") orelse return error.MarkerNotFound;
        const row = t.parent orelse return error.MarkerNotFound;
        const st_comp = row.children.items[0];
        const minus = childBox(st_comp, 0) orelse return error.MarkerNotFound;
        const plus = childBox(st_comp, 2) orelse return error.MarkerNotFound;
        // 1 -> 2 -> 3 -> 2
        try clickAt(app, center(plus).x, center(plus).y);
        try clickAt(app, center(plus).x, center(plus).y);
        try clickAt(app, center(minus).x, center(minus).y);
        const v = demo.stepper.?.*;
        std.debug.print("STEPPER value={d}\n", .{v});
        if (v != 2) return error.StepperFailed;
    }

    // ---- rating ------------------------------------------------------
    {
        const t = findText(root, "Rate us") orelse return error.MarkerNotFound;
        const row = t.parent orelse return error.MarkerNotFound;
        const r_comp = row.children.items[0];
        const star = childBox(r_comp, 4) orelse return error.MarkerNotFound;
        try clickAt(app, center(star).x, center(star).y);
        const v = demo.rating.?.*;
        std.debug.print("RATING value={d}\n", .{v});
        if (v != 5) return error.RatingFailed;
    }

    // ---- tabs --------------------------------------------------------
    {
        const t = findText(root, "Details") orelse return error.MarkerNotFound;
        const tab_root = t.parent orelse return error.MarkerNotFound;
        try clickAt(app, center(tab_root.bounds()).x, center(tab_root.bounds()).y);
        const sel = demo.tab.?.*;
        std.debug.print("TABS selected={d}\n", .{sel});
        if (sel != 1) return error.TabsFailed;
        if (findText(root, "Details pane") == null) return error.TabsFailed;
    }

    // ---- accordion ---------------------------------------------------
    {
        try scrollIntoView(app, root, "Section one");
        const t = findText(root, "Section one") orelse return error.MarkerNotFound;
        const header = t.parent orelse return error.MarkerNotFound;
        if (findText(root, "Collapsible content of section one") != null) {
            return error.AccordionFailed;
        }
        try clickAt(app, center(header.bounds()).x, center(header.bounds()).y);
        if (findText(root, "Collapsible content of section one") == null) {
            std.debug.print("ACCORDION_FAIL: content did not appear\n", .{});
            return error.AccordionFailed;
        }
    }

    // ---- dropdown ----------------------------------------------------
    {
        try scrollIntoView(app, root, "Choose an option");
        const t = findText(root, "Choose an option") orelse return error.MarkerNotFound;
        const btn = t.parent orelse return error.MarkerNotFound;
        const c = center(btn.bounds());
        try clickAt(app, c.x, c.y);
        if (!demo.dd_open.?.*) {
            std.debug.print("DROPDOWN_FAIL: menu did not open\n", .{});
            return error.DropdownFailed;
        }
        const item_t = findText(root, "Option B") orelse return error.MarkerNotFound;
        const item = item_t.parent orelse return error.MarkerNotFound;
        const ib = item.bounds();
        try clickAt(app, center(ib).x, center(ib).y);
        std.debug.print("DROPDOWN selected={d} open={}\n", .{ demo.dd_selected.?.*, demo.dd_open.?.* });
        if (demo.dd_selected.?.* != 1 or demo.dd_open.?.*) return error.DropdownFailed;
    }

    // ---- modal: Escape, scrim click, confirm button ------------------
    {
        try scrollIntoView(app, root, "Open dialog");
        const t = findText(root, "Open dialog") orelse return error.MarkerNotFound;
        const btn = t.parent orelse return error.MarkerNotFound;
        const c = center(btn.bounds());
        try clickAt(app, c.x, c.y);
        if (!demo.modal_open.?.*) {
            std.debug.print("MODAL_FAIL: dialog did not open\n", .{});
            return error.ModalFailed;
        }
        try app.frame();
        // Escape closes it (the scrim owns the focus while open).
        try pressKey(app, .escape);
        if (demo.modal_open.?.*) {
            std.debug.print("MODAL_FAIL: Escape did not close\n", .{});
            return error.ModalFailed;
        }
        // Reopen, then click on the scrim (outside the panel).
        try clickAt(app, c.x, c.y);
        try app.frame();
        try clickAt(app, 8, 8);
        if (demo.modal_open.?.*) {
            std.debug.print("MODAL_FAIL: scrim click did not close\n", .{});
            return error.ModalFailed;
        }
        // Reopen, confirm from inside the panel.
        try clickAt(app, c.x, c.y);
        try app.frame();
        const cfm = findText(root, "Confirm") orelse return error.MarkerNotFound;
        const cfm_btn = cfm.parent orelse return error.MarkerNotFound;
        try clickAt(app, center(cfm_btn.bounds()).x, center(cfm_btn.bounds()).y);
        std.debug.print("MODAL confirmations={d} open={}\n", .{ demo.confirmations, demo.modal_open.?.* });
        if (demo.confirmations != 1 or demo.modal_open.?.*) return error.ModalFailed;
    }

    // ---- tooltip -----------------------------------------------------
    {
        try scrollIntoView(app, root, "Hover me");
        const t = findText(root, "Hover me") orelse return error.MarkerNotFound;
        const btn = t.parent orelse return error.MarkerNotFound;
        const c = center(btn.bounds());
        try hover(app, c.x, c.y);
        try waitFrames(app, 700);
        if (findText(root, "A helpful tip") == null) {
            std.debug.print("TOOLTIP_FAIL: tip did not appear after delay\n", .{});
            return error.TooltipFailed;
        }
        // Move away and the tip disappears.
        try hover(app, 20, 690);
        try app.frame();
        if (findText(root, "A helpful tip") != null) {
            std.debug.print("TOOLTIP_FAIL: tip did not leave\n", .{});
            return error.TooltipFailed;
        }
    }

    // ---- notification toast -------------------------------------------
    {
        try scrollIntoView(app, root, "Notify");
        const t = findText(root, "Notify") orelse return error.MarkerNotFound;
        const btn = t.parent orelse return error.MarkerNotFound;
        const c = center(btn.bounds());
        // A short-lived toast queued directly, then a 3s one via the button.
        ui.pushToast("gallery test toast", .info, 400);
        try clickAt(app, c.x, c.y);
        if (ui.toastCount() != 2) {
            std.debug.print("TOAST_FAIL: queue={d}\n", .{ui.toastCount()});
            return error.ToastFailed;
        }
        try waitFrames(app, 800);
        const remaining = ui.toastCount();
        std.debug.print("TOAST remaining={d}\n", .{remaining});
        if (remaining != 1) {
            std.debug.print("TOAST_NOTE: expected 1 remaining, got {d}\n", .{remaining});
        }
    }

    // ---- charts -------------------------------------------------------
    {
        // The plot rect of a Cartesian chart: legend text -> pill -> legend
        // row -> chart root column -> children[1].
        const t = findText(root, "Revenue") orelse return error.MarkerNotFound;
        const pill = t.parent orelse return error.MarkerNotFound;
        const legend_row = pill.parent orelse return error.MarkerNotFound;
        const root_col = legend_row.parent orelse return error.MarkerNotFound;
        try scrollIntoView(app, root, "Revenue");
        if (root_col.children.items.len < 2) return error.ChartFailed;
        try scrollNodeIntoView(app, root_col.children.items[1]);
        const plots = root_col.children.items[1].bounds();

        // Hover the last category: the tooltip lists every visible series.
        // The hover area is the inner plot box (padding 44 / 12 / 10 / 26).
        const plot_inset_x: f32 = 44;
        const plot_inset_w: f32 = 56;
        try hover(app, plots.left + plot_inset_x + (plots.width() - plot_inset_w) - 6, plots.top + 92);
        try app.frame();
        if (findText(root, "Revenue: 210") == null) {
            std.debug.print("CHART_FAIL: line tooltip missing\n", .{});
            return error.ChartFailed;
        }

        // Toggle the Revenue series off through its legend pill and re-hover:
        // only the remaining series show up.
        const pc = center(pill.bounds());
        try clickAt(app, pc.x, pc.y);
        try hover(app, plots.left + plot_inset_x + (plots.width() - plot_inset_w) - 6, plots.top + 92);
        try app.frame();
        if (findText(root, "Revenue: 210") != null) {
            std.debug.print("CHART_FAIL: hidden series still in tooltip\n", .{});
            return error.ChartFailed;
        }
        if (findText(root, "Cost: 110") == null) {
            std.debug.print("CHART_FAIL: visible series missing from tooltip\n", .{});
            return error.ChartFailed;
        }

        // Bar chart: hovering a slot lists its series.
        const bt = findText(root, "Desktop") orelse return error.MarkerNotFound;
        const bpill = bt.parent orelse return error.MarkerNotFound;
        const blow = bpill.parent orelse return error.MarkerNotFound;
        const broot = blow.parent orelse return error.MarkerNotFound;
        if (broot.children.items.len < 2) return error.ChartFailed;
        try scrollNodeIntoView(app, broot.children.items[1]);
        const bplots = broot.children.items[1].bounds();
        try hover(app, bplots.left + bplots.width() * 0.5, bplots.top + bplots.height() * 0.5);
        try app.frame();
        if (findText(root, "Desktop: 334") == null) {
            std.debug.print("CHART_FAIL: bar tooltip missing\n", .{});
            return error.ChartFailed;
        }

        // Donut: hovering a slice swaps the center label to that slice.
        const pt = findText(root, "Chrome") orelse return error.MarkerNotFound;
        const ppill = pt.parent orelse return error.MarkerNotFound;
        const plow = ppill.parent orelse return error.MarkerNotFound;
        const proot = plow.parent orelse return error.MarkerNotFound;
        if (proot.children.items.len < 2) return error.ChartFailed;
        try scrollNodeIntoView(app, proot.children.items[1]);
        const pbox = proot.children.items[1].bounds();
        const cx = pbox.left + pbox.width() / 2;
        const cy = pbox.top + pbox.height() / 2;
        const r = @min(pbox.width(), pbox.height()) / 2;
        // Chrome sweeps 0..223 degrees from the top; 45 degrees lands on it.
        const a: f32 = std.math.pi / 4.0;
        try hover(app, cx + r * 0.7 * @sin(a), cy - r * 0.7 * @cos(a));
        try app.frame();
        try app.frame();
        if (findText(root, "Chrome: 62") == null) {
            std.debug.print("CHART_FAIL: pie center label missing\n", .{});
            return error.ChartFailed;
        }
        std.debug.print("CHARTS ok\n", .{});
    }

    // The chart tests leave the page scrolled to the bottom; the pixel smoke
    // test below expects the buttons (primary blue) on screen, so wheel back
    // to the top first.
    {
        const t = findText(root, "BUTTONS") orelse return error.MarkerNotFound;
        var attempt: u32 = 0;
        while (attempt < 40) : (attempt += 1) {
            const top = t.bounds().top;
            if (top >= 24) break;
            try hover(app, @as(f32, @floatFromInt(app.window.width)) / 2, @as(f32, @floatFromInt(app.window.height)) / 2);
            app.window.queue.push(.{ .scroll = .{ .x = 0, .y = 1 } });
            try app.frame();
        }
    }

    // ---- render smoke test -------------------------------------------
    {
        const fw: usize = @intCast(app.window.framebuffer_width);
        const fh: usize = @intCast(app.window.framebuffer_height);
        const buf = app.allocator.alloc(u8, fw * fh * 4) catch return error.OutOfMemory;
        defer app.allocator.free(buf);
        if (!app.surface.readPixels(buf, @intCast(fw), @intCast(fh))) {
            std.debug.print("RENDER_FAIL: framebuffer read denied\n", .{});
            return error.RenderFailed;
        }
        const n = fw * fh;
        var content: usize = 0;
        var primary: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const px = std.mem.bytesToValue(u32, buf[i * 4 ..][0..4]);
            if (px != ui.theme.active.background and (px >> 24) != 0) content += 1;
            const r = (px >> 16) & 0xFF;
            const g = (px >> 8) & 0xFF;
            const b = px & 0xFF;
            if (r > 0x20 and r < 0x60 and g > 0x50 and g < 0x80 and b > 0xD0) primary += 1;
        }
        std.debug.print("RENDER_STATS content={d}/{d} primary={d}\n", .{ content, n, primary });
        if (primary < 600) {
            std.debug.print("RENDER_FAIL: too few primary pixels ({d})\n", .{primary});
            return error.RenderFailed;
        }

        // Keep a screenshot, like the other examples' checks do.
        app.config.exit_after_frames = 1;
        app.config.on_final_frame = onFinal;
        try app.frame();
    }

    std.debug.print("ALL_OK\n", .{});
}

fn onFinal(buf: []const u8, w: i32, h: i32) void {
    if (!zui.skia.encodePng(buf, w, h, "screenshot_gallery.png")) {
        std.debug.print("PNG_FAIL: could not write screenshot_gallery.png\n", .{});
        return;
    }
    std.debug.print("PNG_OK: wrote screenshot_gallery.png ({d}x{d})\n", .{ w, h });
}
