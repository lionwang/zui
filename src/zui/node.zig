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
    component,
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

    // --- visual properties (rect / text / image) -----------------------
    style: element.Style = .{},
    /// Owned copy of the text content (text nodes only).
    text: ?[]u8 = null,
    onclick: ?element.Handler = null,
    onmouseenter: ?element.Handler = null,
    onmouseleave: ?element.Handler = null,
    cursor: ?element.Cursor = null,

    // --- caches --------------------------------------------------------
    paragraph: ?skia.Paragraph = null,
    /// Signature of the text + text-style the paragraph was built for.
    paragraph_sig: u64 = 0,
    image: ?skia.Image = null,
    image_sig: u64 = 0,
    /// Borrowed image bytes for the current frame (owned by the element arena).
    image_data: ?[]const u8 = null,
    image_fit: element.Fit = .fill,

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
        if (self.paragraph) |*p| p.destroy();
        if (self.image) |*im| im.destroy();
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
};

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
    F.add(&h, std.mem.asBytes(&@intFromEnum(style.font_weight orelse .normal)));
    if (style.font_family) |fam| F.add(&h, fam);
    return h;
}