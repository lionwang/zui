//! Unit tests for the layout engine and the reconciler.
//!
//! These run without a window (`zig build test`); only rect elements are used
//! so that no font collection / GPU context is needed.

const std = @import("std");
const zui = @import("zui.zig");

const element = zui.element;
const node_mod = zui.node;
const reconcile = zui.reconcile;
const layout = zui.layout;
const context_mod = zui.context;

const Allocator = std.mem.Allocator;

/// Counter for the hook test (cannot be a captured local).
var hook_render_count: i32 = 0;

/// A font collection that is never dereferenced: rect-only trees never shape
/// text, so a zeroed sentinel is enough.
fn dummyFontCollection() zui.skia.FontCollection {
    return .{ .handle = undefined };
}

fn freshRoot(alloc: Allocator) !*node_mod.Node {
    const root = try alloc.create(node_mod.Node);
    root.* = .{ .allocator = alloc, .kind = .rect };
    return root;
}

/// Reconcile `el` into `root` and lay it out in a `width` x `height` box.
fn render(root: *node_mod.Node, alloc: Allocator, el: element.Element, width: f32, height: f32) !void {
    var frame_arena = std.heap.ArenaAllocator.init(alloc);
    defer frame_arena.deinit();
    _ = try reconcile.reconcile(alloc, frame_arena.allocator(), root, el, null);
    try layout.layout(root, .{
        .font_collection = dummyFontCollection(),
        .arena = frame_arena.allocator(),
    }, width, height);
}

test "column stacks children along the vertical axis" {
    const alloc = std.testing.allocator;

    const tree = element.Element{ .rect = .{
        .style = .{ .direction = .column, .padding = .all(5), .gap = 10 },
        .children = &.{
            .{ .rect = .{ .style = .{ .width = 30, .height = 20 } } },
            .{ .rect = .{ .style = .{ .width = 30, .height = 40 } } },
        },
    } };

    const root = try freshRoot(alloc);
    defer root.destroy();
    try render(root, alloc, tree, 200, 200);

    // height = 20 + 40 + gap 10 + padding 10 = 80, width = 30 + padding 10 = 40
    try std.testing.expectApproxEqAbs(@as(f32, 40), root.layout.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80), root.layout.h, 0.01);

    const kids = root.children.items;
    try std.testing.expectEqual(@as(usize, 2), kids.len);
    try std.testing.expectApproxEqAbs(@as(f32, 5), kids[0].layout.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 5), kids[0].layout.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 35), kids[1].layout.y, 0.01);
}

test "row lays children out horizontally" {
    const alloc = std.testing.allocator;

    const tree = element.Element{ .rect = .{
        .style = .{ .direction = .row, .gap = 10 },
        .children = &.{
            .{ .rect = .{ .style = .{ .width = 20, .height = 30 } } },
            .{ .rect = .{ .style = .{ .width = 50, .height = 30 } } },
        },
    } };

    const root = try freshRoot(alloc);
    defer root.destroy();
    try render(root, alloc, tree, 200, 200);

    try std.testing.expectApproxEqAbs(@as(f32, 80), root.layout.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), root.layout.h, 0.01);

    const kids = root.children.items;
    try std.testing.expectApproxEqAbs(@as(f32, 0), kids[0].layout.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), kids[1].layout.x, 0.01);
}

test "flex_grow distributes free space" {
    const alloc = std.testing.allocator;

    const tree = element.Element{ .rect = .{
        .style = .{ .direction = .row, .width = 100, .height = 10 },
        .children = &.{
            .{ .rect = .{ .style = .{ .width = 20, .flex_grow = 1 } } },
            .{ .rect = .{ .style = .{ .width = 20, .flex_grow = 3 } } },
        },
    } };

    const root = try freshRoot(alloc);
    defer root.destroy();
    try render(root, alloc, tree, 200, 200);

    const kids = root.children.items;
    // 60 free px split 1:3 -> 15 and 45.
    try std.testing.expectApproxEqAbs(@as(f32, 35), kids[0].layout.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 65), kids[1].layout.w, 0.01);
}

test "border offsets the content box" {
    const alloc = std.testing.allocator;

    const tree = element.Element{ .rect = .{
        .style = .{ .padding = .all(4), .border = .all(2), .width = 30, .height = 30 },
        .children = &.{
            .{ .rect = .{ .style = .{ .width = 10, .height = 10 } } },
        },
    } };

    const root = try freshRoot(alloc);
    defer root.destroy();
    try render(root, alloc, tree, 200, 200);

    // Content origin = padding(4) + border(2) = 6.
    try std.testing.expectApproxEqAbs(@as(f32, 6), root.layout.cx, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 6), root.layout.cy, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 6), root.children.items[0].layout.x, 0.01);
}

test "justify_content center centers a row" {
    const alloc = std.testing.allocator;

    const tree = element.Element{ .rect = .{
        .style = .{ .direction = .row, .width = 100, .height = 10, .justify_content = .center },
        .children = &.{
            .{ .rect = .{ .style = .{ .width = 20, .height = 10 } } },
        },
    } };

    const root = try freshRoot(alloc);
    defer root.destroy();
    try render(root, alloc, tree, 200, 200);

    // 80 free px -> the child starts at 40.
    try std.testing.expectApproxEqAbs(@as(f32, 40), root.children.items[0].layout.x, 0.01);
}

test "absolute children pin to the content box and stay out of the flow" {
    const alloc = std.testing.allocator;

    const tree = element.Element{ .rect = .{
        .style = .{ .direction = .column, .width = 100, .height = 100, .padding = .all(10), .align_items = .flex_start },
        .children = &.{
            .{ .rect = .{ .style = .{ .width = 20, .height = 20 } } },
            .{ .rect = .{ .style = .{
                .position = .absolute,
                .left = 5,
                .top = 15,
                .width = 30,
                .height = 8,
            } } },
        },
    } };

    const root = try freshRoot(alloc);
    defer root.destroy();
    try render(root, alloc, tree, 200, 200);

    const kids = root.children.items;
    try std.testing.expectEqual(@as(usize, 2), kids.len);
    // The flow child sits at the content origin and is unaffected by the
    // absolute one (no gap, no shared free space).
    try std.testing.expectApproxEqAbs(@as(f32, 10), kids[0].layout.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), kids[0].layout.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), kids[0].layout.w, 0.01);

    // The absolute child is pinned relative to the content origin (10,10).
    try std.testing.expectApproxEqAbs(@as(f32, 15), kids[1].layout.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 25), kids[1].layout.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), kids[1].layout.w, 0.01);
}

test "left + right stretches an absolute child to the content box" {
    const alloc = std.testing.allocator;

    const tree = element.Element{ .rect = .{
        .style = .{ .direction = .column, .width = 100, .height = 100 },
        .children = &.{
            .{ .rect = .{ .style = .{ .position = .absolute, .left = 10, .right = 20, .top = 4, .bottom = 6 } } },
        },
    } };

    const root = try freshRoot(alloc);
    defer root.destroy();
    try render(root, alloc, tree, 200, 200);

    const abs = root.children.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 10), abs.layout.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100 - 10 - 20), abs.layout.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100 - 4 - 6), abs.layout.h, 0.01);
}

test "hook state survives reconciliation" {
    const alloc = std.testing.allocator;

    const S = struct {
        fn render(ctx: *context_mod.Context) element.Element {
            var count = ctx.useState(i32, 100);
            hook_render_count += 1;
            if (hook_render_count == 1) {
                count.set(42);
            }
            return .{ .rect = .{ .style = .{ .width = 1, .height = 1 } } };
        }
    };

    const root = try freshRoot(alloc);
    defer root.destroy();

    // Two "frames": each one builds a fresh element tree and reconciles it.
    for (0..2) |_| {
        var frame_arena = std.heap.ArenaAllocator.init(alloc);
        defer frame_arena.deinit();
        const el = context_mod.makeComponent("counter", S.render);
        _ = try reconcile.reconcile(alloc, frame_arena.allocator(), root, el, null);
    }

    // The component node expanded into its rect child.
    try std.testing.expect(root.child != null);
    // The hook slot must hold the value written during the first frame.
    const slot: *i32 = @as(*i32, @ptrCast(@alignCast(root.hooks.items[0].ptr)));
    try std.testing.expectEqual(@as(i32, 42), slot.*);
}
