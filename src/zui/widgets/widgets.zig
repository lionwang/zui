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
const events = @import("../events.zig");
const node = @import("../node.zig");
const skia = @import("../skia.zig");
const window_mod = @import("../window.zig");

/// Design tokens (colors) the default components read.
pub const theme = @import("theme.zig");
/// Vector icons (24-space path ops) and path helpers (circles, arcs).
pub const icons = @import("icons.zig");

const button_mod = @import("button.zig");
const controls_mod = @import("controls.zig");
const indicators_mod = @import("indicators.zig");
const overlay_mod = @import("overlay.zig");
const panels_mod = @import("panels.zig");
const charts_mod = @import("charts.zig");

pub const ButtonArgs = button_mod.ButtonArgs;
pub const ButtonVariant = button_mod.ButtonVariant;
pub const ButtonSize = button_mod.ButtonSize;
pub const button = button_mod.button;
pub const iconButton = button_mod.iconButton;

pub const ControlArgs = controls_mod.ControlArgs;
pub const checkbox = controls_mod.checkbox;
pub const switchControl = controls_mod.switchControl;
pub const RadioGroupArgs = controls_mod.RadioGroupArgs;
pub const radioGroup = controls_mod.radioGroup;
pub const SliderArgs = controls_mod.SliderArgs;
pub const slider = controls_mod.slider;
pub const StepperArgs = controls_mod.StepperArgs;
pub const stepper = controls_mod.stepper;
pub const RatingArgs = controls_mod.RatingArgs;
pub const rating = controls_mod.rating;

pub const BadgeArgs = indicators_mod.BadgeArgs;
pub const badge = indicators_mod.badge;
pub const TagArgs = indicators_mod.TagArgs;
pub const tag = indicators_mod.tag;
pub const ProgressArgs = indicators_mod.ProgressArgs;
pub const progress = indicators_mod.progress;
pub const ProgressCircleArgs = indicators_mod.ProgressCircleArgs;
pub const progressCircle = indicators_mod.progressCircle;
pub const SpinnerArgs = indicators_mod.SpinnerArgs;
pub const spinner = indicators_mod.spinner;
pub const SkeletonArgs = indicators_mod.SkeletonArgs;
pub const skeleton = indicators_mod.skeleton;
pub const AvatarArgs = indicators_mod.AvatarArgs;
pub const avatar = indicators_mod.avatar;
pub const KbdArgs = indicators_mod.KbdArgs;
pub const kbd = indicators_mod.kbd;
pub const DividerArgs = indicators_mod.DividerArgs;
pub const divider = indicators_mod.divider;

pub const Side = overlay_mod.Side;
pub const PopoverArgs = overlay_mod.PopoverArgs;
pub const popover = overlay_mod.popover;
pub const MenuItem = overlay_mod.MenuItem;
pub const DropdownArgs = overlay_mod.DropdownArgs;
pub const dropdown = overlay_mod.dropdown;
pub const TooltipArgs = overlay_mod.TooltipArgs;
pub const tooltip = overlay_mod.tooltip;
pub const ModalArgs = overlay_mod.ModalArgs;
pub const modal = overlay_mod.modal;
pub const ToastKind = overlay_mod.ToastKind;
pub const Toast = overlay_mod.Toast;
pub const pushToast = overlay_mod.pushToast;
pub const clearToasts = overlay_mod.clearToasts;
pub const toastCount = overlay_mod.toastCount;
pub const ToasterArgs = overlay_mod.ToasterArgs;
pub const toaster = overlay_mod.toaster;

pub const TabsArgs = panels_mod.TabsArgs;
pub const tabs = panels_mod.tabs;
pub const AccordionItem = panels_mod.AccordionItem;
pub const AccordionArgs = panels_mod.AccordionArgs;
pub const accordion = panels_mod.accordion;

pub const LineSeries = charts_mod.LineSeries;
pub const LineChartArgs = charts_mod.LineChartArgs;
pub const lineChart = charts_mod.lineChart;
pub const BarSeries = charts_mod.BarSeries;
pub const BarChartArgs = charts_mod.BarChartArgs;
pub const barChart = charts_mod.barChart;
pub const PieSlice = charts_mod.PieSlice;
pub const PieChartArgs = charts_mod.PieChartArgs;
pub const pieChart = charts_mod.pieChart;

/// Copy a child list into the per-frame arena, deeply, so that it stays
/// valid after the render function has returned: nested `&.{ ... }` child
/// literals live on the render function's stack and would dangle, while the
/// element tree is only read later, during reconciliation. Empty lists are
/// shared.
fn adoptChildren(ctx: *context.Context, children: []const element.Element) []const element.Element {
    if (children.len == 0) return &.{};
    const util = @import("util.zig");
    return util.dupElements(ctx.arena, children) catch
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
    /// Claim the keyboard focus when clicked (the container then receives
    /// `onchar` / `onkey` until another element takes the focus).
    focusable: bool = false,
    /// Claim the keyboard focus as soon as the element appears.
    autofocus: bool = false,
    /// Keep the keyboard focus through clicks on non-focusable content (list
    /// rows, dead space, chrome). For a view's primary input.
    focus_sticky: bool = false,
    onchar: ?element.CharHandler = null,
    onkey: ?element.KeyHandler = null,
    /// Mouse capture: press, then drag, then release, even outside this box.
    onmouse: ?element.MouseHandler = null,
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
        .focusable = args.focusable,
        .focus_sticky = args.focus_sticky,
        .autofocus = args.autofocus,
        .onchar = args.onchar,
        .onkey = args.onkey,
        .onmouse = args.onmouse,
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
        .focusable = args.focusable,
        .focus_sticky = args.focus_sticky,
        .autofocus = args.autofocus,
        .onchar = args.onchar,
        .onkey = args.onkey,
        .onmouse = args.onmouse,
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
        .focusable = args.focusable,
        .focus_sticky = args.focus_sticky,
        .autofocus = args.autofocus,
        .onchar = args.onchar,
        .onkey = args.onkey,
        .onmouse = args.onmouse,
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
        .focusable = args.focusable,
        .focus_sticky = args.focus_sticky,
        .autofocus = args.autofocus,
        .onchar = args.onchar,
        .onkey = args.onkey,
        .onmouse = args.onmouse,
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

pub const ShapeArgs = struct {
    style: element.Style = .{},
    /// Path segments, authored in the `view x view` coordinate space.
    ops: []const element.PathOp = &.{},
    /// Rendered filled (`true`) or stroked (`false`).
    fill: bool = true,
    stroke_width: f32 = 1.6,
    /// Size of the coordinate space the ops are authored in (24 = the common
    /// icon viewBox).
    view: f32 = 24,
    key: ?[]const u8 = null,
};

/// A vector silhouette (icon, glyph or bubble tail). The path data is copied
/// into the per-frame arena for the same reason container children are: the
/// element outlives the render function that built it.
pub fn shape(ctx: *context.Context, args: ShapeArgs) element.Element {
    var style = args.style;
    if (style.width == null) style.width = 24;
    if (style.height == null) style.height = 24;
    const ops = if (args.ops.len == 0)
        &[0]element.PathOp{}
    else
        ctx.arena.dupe(element.PathOp, args.ops) catch
            @panic("zui: out of memory while building the element tree");
    return .{ .shape = .{
        .style = style,
        .ops = ops,
        .fill = args.fill,
        .stroke_width = args.stroke_width,
        .view = args.view,
        .key = args.key,
    } };
}

// ----------------------------------------------------------------------
// Custom title bar (frameless windows)
// ----------------------------------------------------------------------

/// Properties of the custom title bar `App` renders for a frameless window
/// (`AppConfig.system_menu = false`).
pub const TitleBarProps = struct {
    window: *window_mod.Window,
    /// Bar height in logical pixels. Windows 11 uses 32.
    height: f32 = 32,
    /// Bar background. A frameless app usually matches the content behind it.
    background: u32 = 0xFFF3F3F3,
    /// Window-button glyph color.
    icon_color: u32 = 0xFF5A5A5A,
    /// Button hover background (minimize / maximize).
    hover_color: u32 = 0xFFE5E5E5,
    /// Close-button hover background (the Windows red).
    close_hover_color: u32 = 0xFFC42B1C,
    /// Button width.
    button_width: f32 = 46,
};

/// The custom title bar: a full-width strip whose empty area starts the
/// native window drag (double press toggles maximize) followed by minimize,
/// maximize / restore and close buttons. Build it with `titleBarElement`
/// (`App` does that automatically for frameless windows).
const TitleBar = struct {
    fn render(ctx: *context.Context, props: TitleBarProps) element.Element {
        var st = ctx.useState(State, .{ .win = props.window });
        st.ptr.win = props.window;

        const drag_area = rect(ctx, .{
            .style = .{ .flex_grow = 1 },
            .onmouse = .{ .func = dragOnMouse, .data = st.ptr },
        });
        const maximize_ops = if (props.window.maximized()) &restore_ops else &maximize_ops_const;

        return row(ctx, .{
            .style = .{
                .height = props.height,
                .flex_shrink = 0,
                .background = props.background,
                .align_items = .stretch,
            },
            .children = &.{
                drag_area,
                windowButton(ctx, st.ptr, props, .min, &minimize_ops, true, .{ .func = onMinimize, .data = st.ptr }),
                windowButton(ctx, st.ptr, props, .max, maximize_ops, false, .{ .func = onToggleMaximize, .data = st.ptr }),
                windowButton(ctx, st.ptr, props, .close, &close_ops, false, .{ .func = onClose, .data = st.ptr }),
            },
        });
    }

    const Which = enum { none, min, max, close };

    /// Live state: the hovered button and the timestamp of the last press on
    /// the drag area (for double-press detection).
    const State = struct {
        win: *window_mod.Window,
        hovered: Which = .none,
        last_press_ms: u64 = 0,
    };

    /// One caption button: a full-height box with a vector glyph, a hover
    /// background and white glyphs when the close button turns red.
    fn windowButton(
        ctx: *context.Context,
        st: *State,
        props: TitleBarProps,
        which: Which,
        ops: []const element.PathOp,
        fill: bool,
        onclick: ?element.Handler,
    ) element.Element {
        const hot = st.hovered == which;
        const close_hot = hot and which == .close;
        const bg = if (close_hot)
            props.close_hover_color
        else if (hot)
            props.hover_color
        else
            0;
        const icon = if (close_hot) 0xFFFFFFFF else props.icon_color;
        return rect(ctx, .{
            .style = .{
                .width = props.button_width,
                .flex_shrink = 0,
                .background = bg,
                .align_items = .center,
                .justify_content = .center,
            },
            .onclick = onclick,
            .onmouseenter = switch (which) {
                .min => .{ .func = hoverMin, .data = st },
                .max => .{ .func = hoverMax, .data = st },
                .close => .{ .func = hoverClose, .data = st },
                .none => null,
            },
            .onmouseleave = .{ .func = hoverNone, .data = st },
            .children = &.{shape(ctx, .{
                .style = .{ .width = 15, .height = 15, .background = icon },
                .ops = ops,
                .fill = fill,
                .stroke_width = 1.7,
            })},
        });
    }
};

/// Glyphs in a 24x24 space: a bar, two hollow squares and a cross.
const minimize_ops = [_]element.PathOp{
    .{ .rrect = .{ .box = .{ .left = 5.5, .top = 11, .right = 18.5, .bottom = 13 }, .radius = 1 } },
};
const maximize_ops_const = [_]element.PathOp{
    .{ .rrect = .{ .box = .{ .left = 5.5, .top = 5.5, .right = 18.5, .bottom = 18.5 }, .radius = 2 } },
};
const restore_ops = [_]element.PathOp{
    .{ .rrect = .{ .box = .{ .left = 7.5, .top = 4.5, .right = 19.5, .bottom = 16.5 }, .radius = 2 } },
    .{ .rrect = .{ .box = .{ .left = 4.5, .top = 7.5, .right = 16.5, .bottom = 19.5 }, .radius = 2 } },
};
const close_ops = [_]element.PathOp{
    .{ .move_to = .{ .x = 6, .y = 6 } },
    .{ .line_to = .{ .x = 18, .y = 18 } },
    .{ .move_to = .{ .x = 18, .y = 6 } },
    .{ .line_to = .{ .x = 6, .y = 18 } },
    .{ .close = {} },
};

fn onMinimize(p: *anyopaque) void {
    const st: *TitleBar.State = @ptrCast(@alignCast(p));
    st.win.minimize();
}

fn onToggleMaximize(p: *anyopaque) void {
    const st: *TitleBar.State = @ptrCast(@alignCast(p));
    st.win.toggleMaximize();
}

fn onClose(p: *anyopaque) void {
    const st: *TitleBar.State = @ptrCast(@alignCast(p));
    st.win.requestClose();
}

fn setHovered(p: *anyopaque, which: TitleBar.Which) void {
    const st: *TitleBar.State = @ptrCast(@alignCast(p));
    st.hovered = which;
}

fn hoverMin(p: *anyopaque) void {
    setHovered(p, .min);
}

fn hoverMax(p: *anyopaque) void {
    setHovered(p, .max);
}

fn hoverClose(p: *anyopaque) void {
    setHovered(p, .close);
}

fn hoverNone(p: *anyopaque) void {
    setHovered(p, .none);
}

/// The empty strip of the bar: a press starts the native modal drag, and a
/// second press within a double-click interval toggles maximize, exactly
/// like a real caption.
fn dragOnMouse(p: *anyopaque, ev: *const element.MouseEvent) void {
    const st: *TitleBar.State = @ptrCast(@alignCast(p));
    if (ev.button != .left or ev.action != .press) return;
    const now = skia.millis();
    if (now >= st.last_press_ms and now - st.last_press_ms < 400) {
        st.last_press_ms = 0;
        st.win.toggleMaximize();
        return;
    }
    st.last_press_ms = now;
    st.win.startDrag();
}

/// Build the title bar element; the props are boxed in the per-frame arena.
pub fn titleBarElement(arena: std.mem.Allocator, props: TitleBarProps) element.Element {
    return context.makeComponentProps(arena, "titleBar", props, TitleBar.render) catch .{ .none = {} };
}

// ----------------------------------------------------------------------
// Text input
// ----------------------------------------------------------------------

/// Editable UTF-8 text owned by a component's hook. Pass its `State` handle
/// to `textInput` (`ui.textInput`); the component keeps full read/write
/// access to the content (its own hook), while the input element handles the
/// keyboard interaction.
pub const InputBuffer = struct {
    items: std.ArrayList(u8) = .empty,

    /// The current text.
    pub fn text(self: InputBuffer) []const u8 {
        return self.items.items;
    }

    /// Replace the whole content.
    pub fn setText(self: *InputBuffer, allocator: std.mem.Allocator, content: []const u8) !void {
        self.items.clearRetainingCapacity();
        try self.items.appendSlice(allocator, content);
    }

    /// True when there is at least one non-newline character.
    pub fn hasContent(self: InputBuffer) bool {
        for (self.items.items) |b| {
            if (b != '\n' and b != '\r') return true;
        }
        return false;
    }

    /// Remove the last code point.
    pub fn dropLast(self: *InputBuffer) void {
        const s = self.items.items;
        var i = s.len;
        while (i > 0 and (s[i - 1] & 0xC0) == 0x80) i -= 1;
        if (i > 0) i -= 1;
        self.items.shrinkRetainingCapacity(i);
    }

    /// Remove the byte range.
    pub fn deleteRange(self: *InputBuffer, from: usize, to: usize) void {
        const s = self.items.items;
        if (from >= to or to > s.len) return;
        std.mem.copyForwards(u8, s[from..], s[to..]);
        self.items.shrinkRetainingCapacity(s.len - (to - from));
    }

    /// Insert text at a byte offset (clamped to the ends).
    pub fn insertAt(self: *InputBuffer, allocator: std.mem.Allocator, at: usize, content: []const u8) !void {
        const s = self.items.items;
        const pos = @min(at, s.len);
        try self.items.insertSlice(allocator, pos, content);
    }
};

/// The UTF-16 code-unit count of a UTF-8 string (Skia measures text in these).
fn utf16Count(utf8: []const u8) usize {
    var i: usize = 0;
    var units: usize = 0;
    while (i < utf8.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch break;
        const cp = std.unicode.utf8Decode(utf8[i .. i + seq_len]) catch break;
        units += if (cp > 0xFFFF) 2 else 1;
        i += seq_len;
    }
    return units;
}

/// The UTF-8 byte offset where the given UTF-16 code-unit index lives.
fn utf8OffsetForUtf16(utf8: []const u8, target: usize) usize {
    var i: usize = 0;
    var units: usize = 0;
    while (i < utf8.len) {
        if (units >= target) return i;
        const seq_len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch return i;
        const cp = std.unicode.utf8Decode(utf8[i .. i + seq_len]) catch return i;
        units += if (cp > 0xFFFF) 2 else 1;
        i += seq_len;
    }
    return utf8.len;
}

/// The byte slice covering the UTF-16 unit range [start, end).
fn utf8SliceForUtf16(utf8: []const u8, start: usize, end: usize) []const u8 {
    const from = utf8OffsetForUtf16(utf8, start);
    const to = utf8OffsetForUtf16(utf8, end);
    return utf8[from..to];
}

/// Runtime cross-reference for an input element: the handler closures carry
/// this by pointer, refreshed every frame so they always see the current
/// buffer, submit callback and selection.
const InputState = struct {
    alloc: std.mem.Allocator,
    buf: *InputBuffer,
    onsubmit: ?element.Handler = null,
    /// The component node for the input: its expansion (`.child`) is the
    /// input rect. Resolved in the mouse handler at event time, because the
    /// link only exists after reconciliation (a fresh component has no child
    /// yet while its render function runs).
    host: ?*node.Node = null,
    /// Current selection, in UTF-16 code units (`end` exclusive).
    sel_anchor: usize = 0,
    sel_start: usize = 0,
    sel_end: usize = 0,
    sel_active: bool = false,
};

/// True while the state holds a non-empty selection.
fn hasSelection(st: *const InputState) bool {
    return st.sel_active and st.sel_start != st.sel_end;
}

/// Delete the selected text and reset the selection.
fn deleteSelection(st: *InputState) void {
    if (!hasSelection(st)) return;
    const s = st.buf.items.items;
    const from = utf8OffsetForUtf16(s, st.sel_start);
    const to = utf8OffsetForUtf16(s, st.sel_end);
    st.buf.deleteRange(from, to);
    st.sel_active = false;
}

/// The first text child of the input rect: the label whose glyphs are hit.
fn labelNode(rect_node: *node.Node) ?*node.Node {
    for (rect_node.children.items) |c| {
        if (c.kind == .text) return c;
    }
    return null;
}

fn inputOnChar(p: *anyopaque, ev: *const events.Event.CharEvent) void {
    const st: *InputState = @ptrCast(@alignCast(p));
    // Enter and tab arrive as key events; control sequences are shortcuts.
    if (ev.codepoint == '\r' or ev.codepoint == '\n' or ev.codepoint == '\t') return;
    if (ev.mods.control or ev.mods.alt) return;
    if (hasSelection(st)) deleteSelection(st); // typed text replaces the selection
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(ev.codepoint), &buf) catch return;
    st.buf.items.appendSlice(st.alloc, buf[0..n]) catch {};
}

fn inputOnKey(p: *anyopaque, ev: *const events.Event.KeyEvent) void {
    const st: *InputState = @ptrCast(@alignCast(p));
    switch (ev.key) {
        .backspace => {
            if (hasSelection(st)) {
                deleteSelection(st);
            } else {
                st.buf.dropLast();
            }
        },
        .a => {
            if (ev.mods.control) {
                st.sel_anchor = 0;
                st.sel_start = 0;
                st.sel_end = utf16Count(st.buf.items.items);
                st.sel_active = st.sel_end > 0;
            }
        },
        .c => {
            // Copy the selection to the clipboard.
            if (ev.mods.control and hasSelection(st)) {
                const slice = utf8SliceForUtf16(st.buf.items.items, st.sel_start, st.sel_end);
                _ = skia.clipboardSetText(slice);
            }
        },
        .v => {
            // Paste at the selection (replacing it) or at the end.
            if (ev.mods.control) {
                var buf: [8192]u8 = undefined;
                const pasted = skia.clipboardGetText(&buf);
                if (pasted.len > 0) {
                    const at_end = !hasSelection(st);
                    if (!at_end) {
                        // Replace the selection: the caret lands at the cut.
                        const s = st.buf.items.items;
                        const at = utf8OffsetForUtf16(s, st.sel_start);
                        deleteSelection(st);
                        st.buf.insertAt(st.alloc, at, pasted) catch {};
                    } else {
                        st.buf.items.appendSlice(st.alloc, pasted) catch {};
                    }
                }
            }
        },
        .enter => {
            if (ev.mods.shift) {
                st.buf.items.append(st.alloc, '\n') catch {};
            } else if (st.onsubmit) |h| {
                h.func(h.data);
            }
        },
        else => {},
    }
}

/// Drag-to-select: the press anchors the caret position, the drag extends
/// the selection to the glyph under the cursor.
fn inputOnMouse(p: *anyopaque, ev: *const element.MouseEvent) void {
    const st: *InputState = @ptrCast(@alignCast(p));
    if (ev.button != .left) return;
    const rect_node = if (st.host) |h| (h.child orelse return) else return;
    const label = labelNode(rect_node) orelse return;
    const para = label.paragraph orelse return;

    // Paragraph-local coordinates (the label layout already includes any
    // scroll offset baked in by the container).
    const dx = ev.x - label.layout.x;
    const dy = ev.y - label.layout.y;
    const max_units = utf16Count(st.buf.items.items);
    const raw = para.glyphPosition(dx, dy);
    const pos: usize = if (raw < 0) 0 else @min(@as(usize, @intCast(raw)), max_units);

    switch (ev.action) {
        .press => {
            st.sel_anchor = pos;
            st.sel_start = pos;
            st.sel_end = pos;
            st.sel_active = false;
        },
        .move => {
            st.sel_start = @min(st.sel_anchor, pos);
            st.sel_end = @max(st.sel_anchor, pos);
            st.sel_active = st.sel_start != st.sel_end;
        },
        .release => {
            st.sel_active = st.sel_start != st.sel_end;
        },
    }
}

/// Keyboard and mouse handlers for an input, bound to the given buffer and
/// submit callback. Each call allocates one hook on the caller's node
/// (refreshed every frame); use it to make a *region* focusable when the
/// input element itself is only one part of it - e.g. a chat input bar that
/// also holds a send button, so typing keeps flowing after the button was
/// clicked.
pub const InputHandlers = struct {
    state: *InputState,
    onchar: element.CharHandler,
    onkey: element.KeyHandler,
    onmouse: element.MouseHandler,
};

pub fn inputHandlers(
    ctx: *context.Context,
    buffer: context.State(InputBuffer),
    onsubmit: ?element.Handler,
) InputHandlers {
    var st = ctx.useState(InputState, .{
        .alloc = ctx.node.allocator,
        .buf = buffer.ptr,
        .onsubmit = onsubmit,
    });
    // Refresh the volatile fields *individually*: the selection is live state
    // that must survive across frames.
    st.ptr.alloc = ctx.node.allocator;
    st.ptr.buf = buffer.ptr;
    st.ptr.onsubmit = onsubmit;
    // The component node: `host.child` is the input rect (resolved at event
    // time, see `inputOnMouse`).
    st.ptr.host = ctx.node;
    return .{
        .state = st.ptr,
        .onchar = .{ .func = inputOnChar, .data = st.ptr },
        .onkey = .{ .func = inputOnKey, .data = st.ptr },
        .onmouse = .{ .func = inputOnMouse, .data = st.ptr },
    };
}

// ----------------------------------------------------------------------
// Selectable read-only text (message bubbles and the like)
// ----------------------------------------------------------------------

/// Bumped on every mouse press, so a selection made on a previous press is
/// stale and stops painting: clicking anything - another message, the input,
/// empty space - clears the old selection without the owning component
/// having to know about it.
pub var click_generation: u32 = 0;

/// Selection state for a read-only text region, in UTF-16 code units
/// (`end` exclusive, matching Skia's glyph indexing).
pub const TextSelection = struct {
    alloc: std.mem.Allocator,
    /// The selectable content. Must outlive the frame: a slice owned by the
    /// application's data model, not the per-frame arena.
    text: []const u8 = "",
    /// The component node: its expansion (`.child`) is the region rect, but
    /// that link only exists after reconciliation - so it is resolved in the
    /// mouse handler (at event time), not snapshotted here at render time.
    host: ?*node.Node = null,
    anchor: usize = 0,
    start: usize = 0,
    end: usize = 0,
    active: bool = false,
    /// `click_generation` when the selection was last touched.
    gen: u32 = 0,

    /// True while the selection is current and non-empty.
    pub fn hasSelection(self: *const TextSelection) bool {
        return self.active and self.start != self.end and self.gen == click_generation;
    }

    /// The selected UTF-8 slice.
    pub fn slice(self: *const TextSelection) []const u8 {
        return utf8SliceForUtf16(self.text, self.start, self.end);
    }

    /// The selection as a `Style.selection` for the region's text label.
    pub fn selectionStyle(self: *const TextSelection) ?element.Selection {
        if (!self.hasSelection()) return null;
        return .{ .start = self.start, .end = self.end };
    }
};

pub const TextSelectionHandlers = struct {
    state: *TextSelection,
    onkey: element.KeyHandler,
    onmouse: element.MouseHandler,
};

/// Drag-to-select handlers for a read-only text region: attach `onmouse` to
/// the region rect (make it `focusable` too, so the keyboard shortcuts
/// arrive) and pass `state.selectionStyle()` to the text label inside.
/// Ctrl+A selects everything, Ctrl+C copies the selection to the clipboard.
/// `text` must outlive the frame.
pub fn textSelection(ctx: *context.Context, content: []const u8) TextSelectionHandlers {
    var st = ctx.useState(TextSelection, .{ .alloc = ctx.node.allocator });
    st.ptr.alloc = ctx.node.allocator;
    st.ptr.text = content;
    st.ptr.host = ctx.node;
    return .{
        .state = st.ptr,
        .onkey = .{ .func = selectionOnKey, .data = st.ptr },
        .onmouse = .{ .func = selectionOnMouse, .data = st.ptr },
    };
}

/// The text node for `content` inside a region: the label whose glyphs are
/// hit-tested. Matching on the content (not just tree order) keeps regions
/// that embed other text - avatars, badges - on their own label.
fn messageLabel(n: *node.Node, content: []const u8) ?*node.Node {
    if (n.kind == .text) {
        if (n.text != null and std.mem.eql(u8, n.text.?, content)) return n;
        return null;
    }
    if (n.child) |c| {
        if (messageLabel(c, content)) |t| return t;
    }
    for (n.children.items) |c| {
        if (messageLabel(c, content)) |t| return t;
    }
    return null;
}

fn selectionOnKey(p: *anyopaque, ev: *const events.Event.KeyEvent) void {
    const st: *TextSelection = @ptrCast(@alignCast(p));
    switch (ev.key) {
        .c => {
            // Copy the selection to the clipboard.
            if (ev.mods.control and st.hasSelection()) {
                _ = skia.clipboardSetText(st.slice());
            }
        },
        .a => {
            if (ev.mods.control) {
                st.anchor = 0;
                st.start = 0;
                st.end = utf16Count(st.text);
                st.active = st.end > 0;
                st.gen = click_generation;
            }
        },
        else => {},
    }
}

/// Drag-to-select: the press anchors the caret position, the drag extends
/// the selection to the glyph under the cursor.
fn selectionOnMouse(p: *anyopaque, ev: *const element.MouseEvent) void {
    const st: *TextSelection = @ptrCast(@alignCast(p));
    if (ev.button != .left) return;
    const rect_node = if (st.host) |h| (h.child orelse return) else return;
    const label = messageLabel(rect_node, st.text) orelse return;
    const para = label.paragraph orelse return;

    // Paragraph-local coordinates (the label layout is absolute).
    const dx = ev.x - label.layout.x;
    const dy = ev.y - label.layout.y;
    const max_units = utf16Count(st.text);
    const raw = para.glyphPosition(dx, dy);
    const pos: usize = if (raw < 0) 0 else @min(@as(usize, @intCast(raw)), max_units);

    switch (ev.action) {
        .press => {
            // dispatched after the click generation was bumped in App.
            st.gen = click_generation;
            st.anchor = pos;
            st.start = pos;
            st.end = pos;
            st.active = false;
        },
        .move => {
            if (st.gen != click_generation) return;
            st.start = @min(st.anchor, pos);
            st.end = @max(st.anchor, pos);
            st.active = st.start != st.end;
        },
        .release => {
            if (st.gen != click_generation) return;
            st.start = @min(st.anchor, pos);
            st.end = @max(st.anchor, pos);
            st.active = st.start != st.end;
        },
    }
}

pub const TextInputArgs = struct {
    style: element.Style = .{},
    /// Shown (in `style.color`) while the buffer is empty and the field is
    /// not focused; a focused field shows only the caret.
    placeholder: []const u8 = "",
    /// The editable content, a hook of the enclosing component.
    buffer: context.State(InputBuffer),
    /// Fired on Enter (without Shift).
    onsubmit: ?element.Handler = null,
    /// Focus the input as soon as it appears, so typing needs no click
    /// (turn off when the input is not the primary target of the view).
    autofocus: bool = true,
    /// Keep the focus through clicks on non-focusable content (list rows,
    /// dead space, chrome). Turn on for the view's primary input - a chat
    /// composer - and off for transient fields - a search box the user
    /// clicks away from.
    sticky_focus: bool = true,
    /// The caret color. 0 means "follow the text color"; WeChat for
    /// instance types dark text but blinks a brand-green caret.
    caret_color: u32 = 0,
    key: ?[]const u8 = null,
};

/// An editable text field laid out as a single unwrapped line that scrolls
/// horizontally to keep its caret visible: autofocus, click to focus, drag
/// to select, Backspace to delete, Ctrl+A/C/V to select/copy/paste, Enter to
/// submit and Shift+Enter for a newline. The content lives in the caller's
/// hook.
pub fn textInput(ctx: *context.Context, args: TextInputArgs) element.Element {
    return ctx.componentProps("textInput", TextInput.Props{
        .style = args.style,
        .placeholder = args.placeholder,
        .buffer = args.buffer,
        .onsubmit = args.onsubmit,
        .autofocus = args.autofocus,
        .sticky_focus = args.sticky_focus,
        .caret_color = args.caret_color,
    }, TextInput.render);
}

const TextInput = struct {
    const Props = struct {
        style: element.Style = .{},
        placeholder: []const u8 = "",
        buffer: context.State(InputBuffer),
        onsubmit: ?element.Handler = null,
        autofocus: bool = true,
        sticky_focus: bool = true,
        caret_color: u32 = 0,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const handlers = inputHandlers(ctx, props.buffer, props.onsubmit);

        const content = props.buffer.get().text();
        const phase = @divFloor(skia.millis(), 530);
        const caret_on = @mod(phase, 2) == 0;

        var input_style = props.style;
        input_style.direction = .row;
        input_style.align_items = .flex_start;
        input_style.overflow = .hidden;
        input_style.text_align = .left;
        // Horizontal auto-scroll: the content never wraps, and every content
        // change bumps the anchor so the pinned end (the caret) stays
        // visible. `wheel = false` keeps the wheel with the page behind.
        input_style.scroll = .{
            .pin = .bottom,
            .anchor = @intCast(content.len),
            .wheel = false,
        };

        var label_style = input_style;
        label_style.flex_grow = 0;
        label_style.flex_shrink = 0;
        label_style.width = null;
        label_style.height = null;
        label_style.padding = .{};
        label_style.border = .{};
        label_style.background = 0;
        label_style.scroll = null;
        // No auto-wrap: the text stays one line and overflows into the
        // scroll container.
        label_style.no_wrap = true;
        if (hasSelection(handlers.state)) {
            label_style.selection = .{
                .start = handlers.state.sel_start,
                .end = handlers.state.sel_end,
            };
        }
        if (content.len == 0) {
            // The placeholder uses the container's color but is dimmed.
            label_style.color = if (input_style.color == 0xFF000000) 0xFFB2B2B2 else input_style.color;
        }

        // The placeholder is a hint for the *idle* field: drop it once the
        // field is focused, even while it is still empty - the blinking
        // caret already says "type here". The component's single child is
        // the input rect reconciliation reuses each frame, so its `focused`
        // flag (set by `App` on the previous focus change / autofocus)
        // reflects this input's state.
        const focused = if (ctx.node.child) |c| c.focused else false;
        const shown = if (focused) "" else props.placeholder;
        const label = text(label_style, if (content.len == 0) shown else content);
        const caret = rect(ctx, .{
            .style = .{
                .width = 1.5,
                .height = @max(input_style.font_size * 1.2, 14),
                .background = if (props.caret_color != 0) props.caret_color else input_style.color,
                .flex_shrink = 0,
                .margin = .{ .left = 1 },
            },
        });

        return rect(ctx, .{
            .style = input_style,
            .key = null,
            .cursor = .ibeam,
            .focusable = true,
            .autofocus = props.autofocus,
            .focus_sticky = props.sticky_focus,
            .onchar = handlers.onchar,
            .onkey = handlers.onkey,
            .onmouse = handlers.onmouse,
            .children = &.{
                label,
                // The caret belongs to the focused field only: `caret_on` is
                // just the blink phase, so gating on it alone left a blinking
                // caret in a field that lost the focus to another click.
                if (caret_on and focused) caret else .{ .none = {} },
            },
        });
    }
};
