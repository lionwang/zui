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


/// Main axis of a flex container.
pub const Direction = enum {
    column,
    row,
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

    // --- paint --------------------------------------------------------
    /// Fill color (ARGB, 0 = fully transparent).
    background: u32 = 0,
    border_color: u32 = 0,

    // --- text ---------------------------------------------------------
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
        inline for (@typeInfo(@TypeOf(overrides)).Struct.fields) |field| {
            @field(result, field.name) = @field(overrides, field.name);
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
    component: Component,
    /// Renders nothing (used for conditional UI).
    none,


    pub fn isNone(self: Element) bool {
        return self == .none;
    }
};

