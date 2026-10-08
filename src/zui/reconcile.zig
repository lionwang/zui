//! Element-tree reconciliation.
//!
//! Every frame the application builds a fresh, immutable `element.Element`
//! tree in a per-frame arena. `reconcile` walks that tree and mirrors it into
//! a long-lived `node.Node` tree: matching nodes (by kind + key) are updated
//! in place so that their hook state and Skia caches (paragraphs, images)
//! survive, and unmatched nodes are destroyed.
//!
//! This is dioxus's virtual DOM diffing, pared down to what a retained-mode
//! UI needs. It lives in its own module to keep the `element -> node ->
//! context` import graph acyclic.

const std = @import("std");
const element = @import("element.zig");
const node = @import("node.zig");
const context = @import("context.zig");
const window_mod = @import("window.zig");

/// Stand-in for propless components; the wrapper never dereferences it.
var null_props_dummy: u8 = 0;

/// Update `existing` (or create a node) so that it represents `el`.
pub fn reconcile(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    existing: ?*node.Node,
    el: element.Element,
    win: ?*window_mod.Window,
) error{OutOfMemory}!*node.Node {
    const n = existing orelse blk: {
        const created = try allocator.create(node.Node);
        created.* = .{
            .allocator = allocator,
            .kind = kindOf(el),
        };
        try created.setKey(elKey(el));
        break :blk created;
    };
    if (existing != null) {
        try n.setKey(elKey(el));
    }
    try apply(n, el, arena, win);
    return n;
}

/// Which node kind an element produces.
fn kindOf(el: element.Element) node.Kind {
    return switch (el) {
        .rect => .rect,
        .text => .text,
        .image => .image,
        .shape => .shape,
        .component => .component,
        .none => .rect,
    };
}

fn elKey(el: element.Element) ?[]const u8 {
    return switch (el) {
        .rect => |r| r.key,
        .shape => |s| s.key,
        .component => |c| c.key,
        else => null,
    };
}

/// Does `n` match the given element (same kind and key)?
fn matches(n: node.Node, el: element.Element) bool {
    return n.kind == kindOf(el) and
        std.mem.eql(u8, n.key orelse "", elKey(el) orelse "");
}

/// Update a node so it describes `el`.
fn apply(n: *node.Node, el: element.Element, arena: std.mem.Allocator, win: ?*window_mod.Window) !void {
    switch (el) {
        .rect => |r| {
            n.image_data = null;
            n.style = r.style;
            n.onclick = r.onclick;
            n.onmouseenter = r.onmouseenter;
            n.onmouseleave = r.onmouseleave;
            n.cursor = r.cursor;
            n.focusable = r.focusable;
            n.focus_sticky = r.focus_sticky;
            n.autofocus = r.autofocus;
            n.onchar = r.onchar;
            n.onkey = r.onkey;
            n.onmouse = r.onmouse;
            try applyScroll(n, r.style.scroll);
            try n.setText(null);
            try n.setImageSignature(0);
            try n.setShapeOps(null);
            try reconcileChildren(n, r.children, arena, win);
        },
        .text => |t| {
            n.image_data = null;
            n.style = t.style;
            n.onclick = null;
            n.onmouseenter = null;
            n.onmouseleave = null;
            n.cursor = null;
            n.focusable = false;
            n.focus_sticky = false;
            n.autofocus = false;
            n.onchar = null;
            n.onkey = null;
            n.onmouse = null;
            try applyScroll(n, null);
            try n.setText(t.content);
            try n.setImageSignature(0);
            try n.setShapeOps(null);
            try reconcileChildren(n, &.{}, arena, win);
        },
        .image => |im| {
            n.style = im.style;
            n.onclick = null;
            n.onmouseenter = null;
            n.onmouseleave = null;
            n.cursor = null;
            n.focusable = false;
            n.focus_sticky = false;
            n.autofocus = false;
            n.onchar = null;
            n.onkey = null;
            n.onmouse = null;
            try applyScroll(n, null);
            try n.setText(null);
            try n.setImageSignature(signatureImage(im));
            n.image_data = im.data;
            n.image_fit = im.fit;
            try n.setShapeOps(null);
            try reconcileChildren(n, &.{}, arena, win);
        },
        .shape => |s| {
            n.image_data = null;
            n.style = s.style;
            n.onclick = null;
            n.onmouseenter = null;
            n.onmouseleave = null;
            n.cursor = null;
            n.focusable = false;
            n.focus_sticky = false;
            n.autofocus = false;
            n.onchar = null;
            n.onkey = null;
            n.onmouse = null;
            try applyScroll(n, null);
            try n.setText(null);
            try n.setImageSignature(0);
            try n.setShapeOps(s.ops);
            n.shape_fill = s.fill;
            n.shape_stroke_width = s.stroke_width;
            n.shape_view = s.view;
            try reconcileChildren(n, &.{}, arena, win);
        },
        .component => |comp| {
            var ctx = context.Context{
                .arena = arena,
                .node = n,
                .props = comp.props,
                .window = win,
            };
            const child_el = comp.render(
                @as(*anyopaque, @ptrCast(&ctx)),
                comp.props orelse @as(*anyopaque, @ptrCast(&null_props_dummy)),
            );
            if (child_el == .none) {
                // "Render nothing": drop the whole expansion, so no stale
                // geometry or paint state from the previous frame lurks in
                // the tree (a phantom box would swallow hits and paint).
                if (n.child) |c| {
                    c.destroy();
                    n.child = null;
                }
            } else {
                const child = try reconcile(n.allocator, arena, n.child, child_el, win);
                child.parent = n;
                n.child = child;
            }
            // A component renders exactly one element; drop any stale children.
            for (n.children.items) |c| c.destroy();
            n.children.clearRetainingCapacity();
        },
        .none => {
            n.onclick = null;
            n.onmouseenter = null;
            n.onmouseleave = null;
            n.focusable = false;
            n.focus_sticky = false;
            n.autofocus = false;
            n.onchar = null;
            n.onkey = null;
            n.onmouse = null;
            try applyScroll(n, null);
            try n.setText(null);
            try n.setImageSignature(0);
            try n.setShapeOps(null);
            try reconcileChildren(n, &.{}, arena, win);
        },
    }
}

/// Mirror the declarative scroll spec into the retained scroll state. The
/// offset itself is runtime state and is never touched here.
fn applyScroll(n: *node.Node, spec: ?element.Scroll) !void {
    if (spec) |s| {
        if (n.scroll == null) n.scroll = .{};
        n.scroll.?.spec = s;
    } else {
        n.scroll = null;
    }
}

/// Reconcile a list of child elements, reusing matching old nodes.
fn reconcileChildren(n: *node.Node, children: []const element.Element, arena: std.mem.Allocator, win: ?*window_mod.Window) !void {
    const alloc = n.allocator;
    const old_items = n.children.items;
    var taken = try alloc.alloc(bool, old_items.len);
    defer alloc.free(taken);
    @memset(taken, false);

    var new_list: std.ArrayList(*node.Node) = .empty;
    errdefer new_list.deinit(alloc);

    for (children) |child_el| {
        if (child_el == .none) continue;
        var match: ?*node.Node = null;
        for (old_items, 0..) |old_node, i| {
            if (taken[i]) continue;
            if (matches(old_node.*, child_el)) {
                taken[i] = true;
                match = old_node;
                break;
            }
        }
        const reconciled = try reconcile(alloc, arena, match, child_el, win);
        try new_list.append(alloc, reconciled);
    }

    for (old_items, 0..) |old_node, i| {
        if (!taken[i]) old_node.destroy();
    }
    for (new_list.items) |child| child.parent = n;
    n.children.deinit(alloc);
    n.children = new_list;
}

fn signatureImage(im: element.Image) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (im.data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    if (im.path) |p| {
        for (p) |b| {
            h ^= b;
            h *%= 0x100000001b3;
        }
    }
    return h;
}
