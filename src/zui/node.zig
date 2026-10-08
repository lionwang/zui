//! The retained element tree.
//!
//! Nodes are the long-lived counterpart of the per-frame
//! `element.Element` tree: they own hook storage, cached Skia objects
//! (paragraphs, decoded images) and the computed layout box. Nodes are
//! created and pruned by `reconcile.zig`.
//!
//! Conceptually this is dioxus's retained real-DOM.

const std = @import("std");
const element = @import("element.zig");
const skia = @import("skia.zig");

pub const Kind = enum {
    rect,
    text,
    image,
    shape,
    component,
};

/// Retained scroll state for a rect whose style declares `.scroll`.
///
/// The offset is mutated by the wheel handler and, on anchor changes, by the
/// layout pass (which also clamps it and refreshes the content measurement).
pub const ScrollState = struct {
    spec: element.Scroll = .{},
    offset: f32 = 0,
    /// Height of the laid-out content (children + gaps + padding).
    content_h: f32 = 0,
    /// Height of the container itself, from the last layout pass.
    viewport_h: f32 = 0,
    /// The `anchor` value the offset was last pinned for. Initialized so the
    /// first layout always (re)pins, even for an anchor of 0.
    pinned_for: u32 = std.math.maxInt(u32),

    /// Furthest the content can be scrolled; 0 when it fits the viewport.
    pub fn maxOffset(self: ScrollState) f32 {
        return @max(0, self.content_h - self.viewport_h);
    }
};

/// A hook slot owned by a component node.
pub const Hook = struct {
    ptr: *anyopaque,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// Computed geometry for a node, in absolute logical pixels.
pub const Layout = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    /// Origin of the content box (border box inset by padding + border).
    cx: f32 = 0,
    cy: f32 = 0,
};

pub const Node = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    /// Optional reconciliation key (Freya-style); positional otherwise.
    key: ?[]const u8 = null,

    /// Hook storage for component nodes.
    hooks: std.ArrayList(Hook) = .empty,
    /// The single expanded child of a component node.
    child: ?*Node = null,
    /// Children of rect nodes.
    children: std.ArrayList(*Node) = .empty,
    /// Parent node, set during reconciliation (used by event bubbling).
    parent: ?*Node = null,

    // --- visual properties (rect / text / image / shape) ----------------
    style: element.Style = .{},
    /// Owned copy of the text content (text nodes only).
    text: ?[]u8 = null,
    onclick: ?element.Handler = null,
    onmouseenter: ?element.Handler = null,
    onmouseleave: ?element.Handler = null,
    cursor: ?element.Cursor = null,
    focusable: bool = false,
    autofocus: bool = false,
    /// Whether this node is the app's current focus target. Toggled by
    /// `App.setFocus` (which only touches nodes still in the tree), and read
    /// while rendering: an input hides its placeholder once it is focused.
    focused: bool = false,
    /// True on the view's primary input: it keeps the focus when the user
    /// clicks something that is not focusable (a list row, dead space,
    /// chrome), so typing is not interrupted. See `element.Rect`.
    focus_sticky: bool = false,
    onchar: ?element.CharHandler = null,
    onkey: ?element.KeyHandler = null,
    onmouse: ?element.MouseHandler = null,
    scroll: ?ScrollState = null,

    // --- caches --------------------------------------------------------
    paragraph: ?skia.Paragraph = null,
    /// Signature of the text + text-style the paragraph was built for.
    paragraph_sig: u64 = 0,
    image: ?skia.Image = null,
    image_sig: u64 = 0,
    /// Borrowed image bytes for the current frame (owned by the element arena).
    image_data: ?[]const u8 = null,
    image_fit: element.Fit = .fill,

    // --- shape ----------------------------------------------------------
    /// Owned copy of the path ops (shape nodes only).
    shape_ops: ?[]element.PathOp = null,
    shape_fill: bool = true,
    shape_stroke_width: f32 = 1.6,
    shape_view: f32 = 24,
    path: ?skia.Path = null,
    /// Signature of the ops + style the cached path was built for.
    path_sig: u64 = 0,

    // --- layout output -------------------------------------------------
    layout: Layout = .{},

    /// Recursively free everything the node owns.
    pub fn destroy(self: *Node) void {
        const alloc = self.allocator;
        for (self.hooks.items) |hook| hook.deinit(hook.ptr, alloc);
        self.hooks.deinit(alloc);
        if (self.child) |c| c.destroy();
        for (self.children.items) |c| c.destroy();
        self.children.deinit(alloc);
        if (self.text) |t| alloc.free(t);
        if (self.key) |k| alloc.free(k);
        if (self.paragraph) |*p| p.destroy();
        if (self.image) |*im| im.destroy();
        if (self.shape_ops) |ops| alloc.free(ops);
        if (self.path) |*p| p.destroy();
        alloc.destroy(self);
    }

    /// Absolute border box of the node.
    pub fn bounds(self: Node) skia.Rect {
        return .{
            .left = self.layout.x,
            .top = self.layout.y,
            .right = self.layout.x + self.layout.w,
            .bottom = self.layout.y + self.layout.h,
        };
    }

    /// Replace the owned reconciliation key, freeing the previous copy.
    /// Element keys may live in the per-frame arena, so nodes must own them:
    /// `matches` reads the key of a retained node during later frames.
    pub fn setKey(self: *Node, key: ?[]const u8) !void {
        const alloc = self.allocator;
        if (self.key) |old| {
            if (key) |k| {
                if (std.mem.eql(u8, old, k)) return;
            }
            alloc.free(old);
            self.key = null;
        }
        if (key) |k| self.key = try alloc.dupe(u8, k);
    }

    /// Replace the owned text content, freeing the previous copy.
    pub fn setText(self: *Node, content: ?[]const u8) !void {
        const alloc = self.allocator;
        if (self.text) |old| {
            if (content) |c| {
                if (std.mem.eql(u8, old, c)) return;
            }
            alloc.free(old);
            self.text = null;
        }
        if (content) |c| {
            self.text = try alloc.dupe(u8, c);
        }
    }

    pub fn setImageSignature(self: *Node, sig: u64) !void {
        if (self.image_sig != sig) {
            if (self.image) |*im| {
                im.destroy();
                self.image = null;
            }
            self.image_sig = sig;
        }
    }

    /// Lazily build (or reuse) the Skia paragraph for a text node.
    pub fn paragraphFor(self: *Node, fc: skia.FontCollection, arena: std.mem.Allocator) !skia.Paragraph {
        const content = self.text orelse "";
        const sig = signatureText(self.style, content);
        if (self.paragraph) |*p| {
            if (self.paragraph_sig == sig) return p.*;
            p.destroy();
            self.paragraph = null;
        }
        var builder = try skia.ParagraphBuilder.create(fc, .{
            .alignment = switch (self.style.text_align) {
                .left => .left,
                .center => .center,
                .right => .right,
            },
            .max_lines = if (self.style.max_lines > 0) @intCast(self.style.max_lines) else 0,
            .ellipsis = self.style.max_lines > 0,
            .height_multiplier = 0,
        });
        defer builder.destroy();
        try builder.pushStyle(.{
            .color = self.style.color,
            .font_size = self.style.font_size,
            .height_multiplier = self.style.line_height,
            .letter_spacing = self.style.letter_spacing,
            .weight = self.style.font_weight orelse .normal,
            .slant = if (self.style.italic) .italic else .upright,
            .font_family = self.style.font_family,
            .decoration = .{
                .underline = self.style.underline,
                .strikethrough = self.style.strikethrough,
            },
        }, arena);
        builder.addText(content);
        builder.pop();
        const para = try builder.build();
        self.paragraph = para;
        self.paragraph_sig = sig;
        return para;
    }

    /// Lazily decode (or reuse) the Skia image for an image node.
    pub fn imageFor(self: *Node) !skia.Image {
        if (self.image) |*im| return im.*;
        const data = self.image_data orelse return error.NoImageData;
        const im = try skia.Image.fromEncoded(data);
        self.image = im;
        return im;
    }

    /// Replace the owned path ops, freeing the previous copy. `pathFor` keeps
    /// its own signature, so unchanged geometry still reuses the Skia cache.
    pub fn setShapeOps(self: *Node, ops: ?[]const element.PathOp) !void {
        const alloc = self.allocator;
        if (self.shape_ops) |old| {
            alloc.free(old);
            self.shape_ops = null;
        }
        if (ops) |new| {
            self.shape_ops = try alloc.dupe(element.PathOp, new);
        }
    }

    /// Lazily build (or reuse) the Skia path for a shape node.
    pub fn pathFor(self: *Node) !skia.Path {
        const ops = self.shape_ops orelse return error.NoPathOps;
        const sig = signatureOps(self.shape_view, ops);
        if (self.path) |*p| {
            if (self.path_sig == sig) return p.*;
            p.destroy();
            self.path = null;
        }
        var path = try skia.Path.create();
        errdefer path.destroy();
        for (ops) |op| switch (op) {
            .move_to => |pt| path.moveTo(pt.x, pt.y),
            .line_to => |pt| path.lineTo(pt.x, pt.y),
            .quad_to => |q| path.quadTo(q.c.x, q.c.y, q.p.x, q.p.y),
            .cubic_to => |c| path.cubicTo(c.c1.x, c.c1.y, c.c2.x, c.c2.y, c.p.x, c.p.y),
            .close => path.close(),
            .rrect => |rr| {
                const b = rr.box;
                path.addRRect(.{
                    .left = b.left,
                    .top = b.top,
                    .right = b.right,
                    .bottom = b.bottom,
                }, rr.radius, rr.radius);
            },
        };
        self.path = path;
        self.path_sig = sig;
        return path;
    }
};

/// Hash the shape view size + every path op, so the Skia path is only rebuilt
/// when the geometry actually changed.
fn signatureOps(view: f32, ops: []const element.PathOp) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const F = struct {
        fn add(hash: *u64, bytes: anytype) void {
            for (bytes) |b| {
                hash.* ^= b;
                hash.* *%= 0x100000001b3;
            }
        }
    };
    F.add(&h, std.mem.asBytes(&view));
    for (ops) |op| switch (op) {
        .move_to, .line_to => |pt| {
            F.add(&h, std.mem.asBytes(&pt.x));
            F.add(&h, std.mem.asBytes(&pt.y));
        },
        .quad_to => |q| {
            F.add(&h, std.mem.asBytes(&q.c.x));
            F.add(&h, std.mem.asBytes(&q.c.y));
            F.add(&h, std.mem.asBytes(&q.p.x));
            F.add(&h, std.mem.asBytes(&q.p.y));
        },
        .cubic_to => |c| {
            F.add(&h, std.mem.asBytes(&c.c1.x));
            F.add(&h, std.mem.asBytes(&c.c1.y));
            F.add(&h, std.mem.asBytes(&c.c2.x));
            F.add(&h, std.mem.asBytes(&c.c2.y));
            F.add(&h, std.mem.asBytes(&c.p.x));
            F.add(&h, std.mem.asBytes(&c.p.y));
        },
        .close => F.add(&h, &[_]u8{0}),
        .rrect => |rr| {
            F.add(&h, &[_]u8{1});
            F.add(&h, std.mem.asBytes(&rr.box));
            F.add(&h, std.mem.asBytes(&rr.radius));
        },
    };
    return h;
}

/// Hash the parts of a style + content that affect text shaping, so a
/// paragraph is only rebuilt when something actually changed.
fn signatureText(style: element.Style, content: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const F = struct {
        fn add(hash: *u64, bytes: anytype) void {
            for (bytes) |b| {
                hash.* ^= b;
                hash.* *%= 0x100000001b3;
            }
        }
    };
    F.add(&h, content);
    F.add(&h, std.mem.asBytes(&style.font_size));
    F.add(&h, std.mem.asBytes(&style.line_height));
    F.add(&h, std.mem.asBytes(&style.color));
    F.add(&h, std.mem.asBytes(&style.letter_spacing));
    F.add(&h, std.mem.asBytes(&style.max_lines));
    const flags = [_]u8{ @intFromBool(style.italic), @intFromBool(style.underline), @intFromBool(style.strikethrough) };
    F.add(&h, &flags);
    F.add(&h, std.mem.asBytes(&@backingInt(style.font_weight orelse .normal)));
    if (style.font_family) |fam| F.add(&h, fam);
    return h;
}
