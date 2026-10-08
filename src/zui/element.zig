//! Virtual DOM elements and styles.
//!
//! An `Element` is an immutable description of a piece of UI. Every frame the
//! application builds a fresh tree of elements (in a per-frame arena); the
//! runtime reconciles it against the retained `node.Node` tree, which owns
//! long-lived state such as hook storage and cached text paragraphs.
//!
//! This mirrors Freya's dioxus layer, where components are plain functions
//! that return elements and state is held by hooks.

const std = @import("std");
const skia = @import("skia.zig");
const events = @import("events.zig");

/// Main axis of a flex container.
pub const Direction = enum {
    column,
    row,
};

/// Whether an element flows with its siblings or is pinned to the parent's
/// content box (see `Style.position`).
pub const Position = enum {
    relative,
    absolute,
};

/// Cross/main axis alignment (a subset of CSS flexbox).
pub const Align = enum {
    flex_start,
    center,
    flex_end,
    stretch,
};

pub const Justify = enum {
    flex_start,
    center,
    flex_end,
    space_between,
    space_evenly,
};

pub const Overflow = enum {
    visible,
    hidden,
};

pub const TextAlign = enum {
    left,
    center,
    right,
};

/// An arbitrary set of box edges (padding, margin or border).
pub const Edges = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn all(v: f32) Edges {
        return .{ .left = v, .top = v, .right = v, .bottom = v };
    }

    pub fn axis(v: f32, is_horizontal: bool) Edges {
        if (is_horizontal) return .{ .left = v, .right = v };
        return .{ .top = v, .bottom = v };
    }

    pub fn horizontal(self: Edges) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Edges) f32 {
        return self.top + self.bottom;
    }
};

/// Visual + layout attributes shared by every element kind.
pub const Style = struct {
    // --- sizing -------------------------------------------------------
    /// Exact width in logical pixels (`null` = content determined).
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: ?f32 = null,
    min_height: ?f32 = null,
    max_width: ?f32 = null,
    max_height: ?f32 = null,

    // --- flex ---------------------------------------------------------
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    /// Initial main size before free space is distributed.
    flex_basis: ?f32 = null,
    direction: Direction = .column,
    wrap: bool = false,
    /// Spacing between children along the main axis.
    gap: f32 = 0,
    align_items: Align = .stretch,
    /// Overrides the container's `align_items` for this element.
    align_self: ?Align = null,
    justify_content: Justify = .flex_start,

    // --- box ----------------------------------------------------------
    padding: Edges = .{},
    margin: Edges = .{},
    border: Edges = .{},
    border_radius: f32 = 0,
    overflow: Overflow = .visible,

    // --- positioning ---------------------------------------------------
    /// `relative` (the default) flows with its siblings; `absolute` takes
    /// the element out of the flow and pins it to the parent's content box
    /// at `left` / `top` - with both `left` and `right` (or `top` and
    /// `bottom`) set it stretches instead of using its natural size. This is
    /// how overlays work: menus, tooltips, modals and toasts are absolute
    /// elements placed as the *last* child of their host, so they paint and
    /// hit-test on top of everything before them.
    position: Position = .relative,
    left: ?f32 = null,
    top: ?f32 = null,
    right: ?f32 = null,
    bottom: ?f32 = null,

    // --- paint --------------------------------------------------------
    /// Fill color (ARGB, 0 = fully transparent).
    background: u32 = 0,
    border_color: u32 = 0,

    // --- scrolling ----------------------------------------------------
    /// Marks this rect as a scroll container and describes how its scroll
    /// offset is managed (see `Scroll`). `null` (the default) means the rect
    /// is laid out and painted normally, with no scroll behavior.
    ///
    /// A scroll container clips its children (`overflow` is implied to be
    /// hidden), lays them out at their natural sizes and offsets the whole
    /// content by `ScrollState.offset`, which the wheel event updates. Its
    /// measured box is the size the parent gives it (the content is ignored
    /// for measurement), so it plays the role of `flex_grow` filler.
    scroll: ?Scroll = null,

    // --- text ---------------------------------------------------------
    /// Do not auto-wrap: the text lays out at its full intrinsic width
    /// (explicit '\n' still breaks lines). Combined with `overflow: hidden`
    /// this is how single-line inputs and horizontally scrolling labels work.
    no_wrap: bool = false,
    /// Selected glyph range (UTF-16 code units, `end` exclusive) painted as
    /// a highlight over the text - a text selection. `null` = none.
    selection: ?Selection = null,
    /// Highlight color for `selection`. The highlight covers whole line
    /// boxes and is painted before the glyphs, so a light opaque color keeps
    /// dark text readable (the classic #ADD6FF editor selection blue).
    selection_color: u32 = 0xFFADD6FF,

    color: u32 = 0xFF000000,
    font_size: f32 = 16,
    /// Multiplier applied to the line height.
    line_height: f32 = 1.35,
    text_align: TextAlign = .left,
    font_family: ?[]const u8 = null,
    font_weight: ?skia.FontWeight = null,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    /// Letter spacing in logical pixels.
    letter_spacing: f32 = 0,
    /// Maximum number of text lines before ellipsizing (0 = unlimited).
    max_lines: u32 = 0,

    /// Effective gap along the main axis.
    pub fn mainGap(self: Style) f32 {
        return self.gap;
    }
    /// Returns the style with the given fields overridden. This is the
    /// idiomatic way to derive styles: `base.with(.{ .background = ... })`.
    pub fn with(self: Style, overrides: anytype) Style {
        var result = self;
        const info = @typeInfo(@TypeOf(overrides)).@"struct";
        inline for (info.field_names) |name| {
            @field(result, name) = @field(overrides, name);
        }
        return result;
    }
};

/// A callback with an opaque user-data pointer. Because Zig has no closures,
/// handlers carry their data explicitly; the data almost always points into a
/// stable hook slot owned by the retained node (see `Context.useState`), so it
/// stays valid across frames.
pub const Handler = struct {
    func: *const fn (*anyopaque) void,
    data: *anyopaque,
};

/// Declarative description of a scroll container (see `Style.scroll`).
pub const Scroll = struct {
    /// Where the content is pinned whenever `anchor` changes value: `.bottom`
    /// scrolls to show the *end* of the content, `.top` the *beginning* -
    /// for a horizontal (row) container, read them as right and left end.
    /// Between anchor bumps the offset is entirely under wheel control.
    pin: Pin = .top,
    /// A value that identifies the current content revision. Layout reapplies
    /// the pin whenever the value differs from the one the retained node last
    /// observed, so appending an item ("a new message arrived") is as simple
    /// as bumping the anchor (e.g. passing the item count).
    anchor: u32 = 0,
    /// Whether the wheel can move this container. `false` keeps the offset
    /// purely under anchor control (an input that always shows its caret,
    /// while the wheel keeps scrolling the page behind it).
    wheel: bool = true,
};

/// A selected glyph range, in UTF-16 code units (`end` exclusive), painted
/// as a highlight over the text.
pub const Selection = struct {
    start: usize = 0,
    end: usize = 0,
};

/// Mouse phase for `MouseHandler` deliveries.
pub const MouseAction = enum {
    press,
    move,
    release,
};

/// A mouse event delivered to the element that captured the press (and to
/// it alone, until release). Coordinates are in logical pixels.
pub const MouseEvent = struct {
    x: f32,
    y: f32,
    action: MouseAction,
    button: events.MouseButton,
};

/// Mouse handler variant: the element that the press landed on (bubbling up
/// to the first ancestor with a handler) receives the whole press/drag/
/// release sequence, even when the cursor leaves its box meanwhile.
pub const MouseHandler = struct {
    func: *const fn (*anyopaque, *const MouseEvent) void,
    data: *anyopaque,
};

/// Where a scroll container snaps its content on an anchor change.
pub const Pin = enum {
    top,
    bottom,
};

/// Keyboard handlers receive the event payload in addition to the data
/// pointer, unlike `Handler`, which is reserved for mouse events. They fire
/// only while the element owns the keyboard focus (see `Rect.focusable`).
pub const KeyHandler = struct {
    func: *const fn (*anyopaque, *const events.Event.KeyEvent) void,
    data: *anyopaque,
};

pub const CharHandler = struct {
    func: *const fn (*anyopaque, *const events.Event.CharEvent) void,
    data: *anyopaque,
};

/// A leaf or container element that draws something.
pub const Rect = struct {
    /// Optional reconciliation key.
    key: ?[]const u8 = null,
    style: Style = .{},
    children: []const Element = &.{},
    onclick: ?Handler = null,
    onmouseenter: ?Handler = null,
    onmouseleave: ?Handler = null,
    cursor: ?Cursor = null,
    /// Claim the keyboard focus when clicked.
    focusable: bool = false,
    /// Claim the keyboard focus as soon as the element appears (the first
    /// frame nothing else is focused). At most one such element should be
    /// visible at a time.
    autofocus: bool = false,
    /// Keep the keyboard focus when the user clicks something that is not
    /// focusable (a list row, dead space, chrome). For a view's primary
    /// input - a chat composer - so clicking around the app does not
    /// interrupt typing. A regular field (a search box) loses the focus
    /// instead, the way clicking away from it should.
    focus_sticky: bool = false,
    /// Character input handler, active while this element owns the focus.
    onchar: ?CharHandler = null,
    /// Key press handler, active while this element owns the focus.
    onkey: ?KeyHandler = null,
    /// Mouse capture handler: press, then drag, then release, even outside.
    onmouse: ?MouseHandler = null,
};

/// A cursor shape requested by an element.
pub const Cursor = enum {
    arrow,
    hand,
    ibeam,
};

/// A run of shaped text.
pub const Text = struct {
    style: Style = .{},
    content: []const u8 = "",
};

/// A raster image.
pub const Image = struct {
    style: Style = .{},
    /// Bytes of a decoded image (PNG / JPEG / ...). Owned by the element tree
    /// arena; the retained node caches the decoded `skia.Image`.
    data: []const u8 = &.{},
    /// Optional file path, loaded once and cached by the retained node.
    path: ?[:0]const u8 = null,
    fit: Fit = .contain,
};

pub const Fit = enum {
    contain,
    cover,
    fill,
    none,
};

/// A point in a shape's own coordinate space (before the `view` scale).
pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// A box in a shape's own coordinate space, as (left, top, right, bottom).
pub const Box = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
};

/// One segment of a vector path. Coordinates live in a square `0 .. view`
/// space (`view` defaults to 24, the common icon viewBox), which the painter
/// scales to the element box, so the same path data renders at any size.
pub const PathOp = union(enum) {
    /// Begin a new subpath at the given point.
    move_to: Point,
    /// Straight line to the given point.
    line_to: Point,
    /// Quadratic Bezier through one control point.
    quad_to: struct { c: Point, p: Point },
    /// Cubic Bezier through two control points.
    cubic_to: struct { c1: Point, c2: Point, p: Point },
    /// Close the current subpath with a straight line.
    close: void,
    /// A rounded rectangle as its own subpath.
    rrect: struct {
        box: Box = .{},
        radius: f32 = 0,
    },
};

/// A vector silhouette: icons, glyphs and the little triangles chat bubbles
/// use as tails. Either filled with `style.background` or stroked with it
/// (`stroke_width` units are in the path coordinate space, so strokes scale
/// with the element like everything else).
pub const Shape = struct {
    style: Style = .{},
    /// Path segments. Typically a `&.{ ... }` literal of static data.
    ops: []const PathOp = &.{},
    /// Rendered filled (`true`) or stroked (`false`).
    fill: bool = true,
    stroke_width: f32 = 1.6,
    /// Size of the coordinate space the ops are authored in.
    view: f32 = 24,
    key: ?[]const u8 = null,
};

/// A component: a plain function that renders an element tree. Components may
/// be parameterized; `componentProps` boxes the props in the frame arena.
pub const Component = struct {
    name: []const u8,
    key: ?[]const u8 = null,
    /// Called with the render Context and the boxed props, both as opaque
    /// pointers so that this module does not depend on context.Context.
    render: *const fn (*anyopaque, *anyopaque) Element,
    props: ?*anyopaque = null,
};

/// One node in the virtual DOM.
pub const Element = union(enum) {
    rect: Rect,
    text: Text,
    image: Image,
    shape: Shape,
    component: Component,
    /// Renders nothing (used for conditional UI).
    none,

    pub fn isNone(self: Element) bool {
        return self == .none;
    }
};
