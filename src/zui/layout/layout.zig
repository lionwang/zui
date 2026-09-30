//! A small flexbox layout engine (a subset of what Freya gets from taffy).
//!
//! Supported features: column / row direction, gap, padding, margin, border,
//! fixed width / height, min / max size, flex-grow / flex-shrink / flex-basis,
//! align-items / align-self, justify-content and text measurement through
//! Skia's paragraph layout. Flex-wrap is not (yet) implemented.
//!
//! Layout runs in two passes over the retained `node.Node` tree:
//!   * `compute` - bottom-up: "how big does this node want to be?" given the
//!     space its parent can offer.
//!   * `arrange` - top-down: assign the final box and position the children.

const std = @import("std");
const node = @import("../node.zig");
const skia = @import("../skia.zig");

pub const LayoutContext = struct {
    font_collection: skia.FontCollection,
    arena: std.mem.Allocator,
};

const Size = struct { w: f32, h: f32 };

/// Lay out `root` to fill `width` x `height` logical pixels.
pub fn layout(root: *node.Node, lctx: LayoutContext, width: f32, height: f32) !void {
    const size = try compute(root, lctx, @max(width, 0), @max(height, 0));
    try arrange(root, lctx, 0, 0, @max(size.w, 0), @max(size.h, 0));
}

fn clampSize(style: anytype, w: f32, h: f32) Size {
    var sw = w;
    var sh = h;
    if (style.min_width) |v| sw = @max(sw, v);
    if (style.max_width) |v| sw = @min(sw, v);
    if (style.min_height) |v| sh = @max(sh, v);
    if (style.max_height) |v| sh = @min(sh, v);
    return .{ .w = @max(sw, 0), .h = @max(sh, 0) };
}

/// Bottom-up measurement pass.
fn compute(n: *node.Node, lctx: LayoutContext, avail_w: f32, avail_h: f32) !Size {
    const s = n.style;

    switch (n.kind) {
        .text => {
            var para = try n.paragraphFor(lctx.font_collection, lctx.arena);
            const max_intrinsic = para.maxIntrinsicWidth();
            const wrap_width = if (avail_w > max_intrinsic) max_intrinsic else avail_w;
            para.layout(@max(wrap_width, 0));
            var w: f32 = para.width();
            var h: f32 = para.height();
            if (s.width) |cw| w = cw;
            if (s.height) |ch| h = ch;
            return clampSize(s, w, h);
        },
        .image => {
            var w: f32 = 0;
            var h: f32 = 0;
            if (n.image) |im| {
                const sz = im.size();
                w = @floatFromInt(sz.width);
                h = @floatFromInt(sz.height);
            }
            if (s.width) |cw| w = cw;
            if (s.height) |ch| h = ch;
            return clampSize(s, w, h);
        },
        .component => {
            if (n.child) |c| return compute(c, lctx, avail_w, avail_h);
            return clampSize(s, 0, 0);
        },
        .rect => {
            const inner_w = @max(avail_w - s.padding.horizontal() - s.border.horizontal(), 0);
            const inner_h = @max(avail_h - s.padding.vertical() - s.border.vertical(), 0);
            const row = s.direction == .row;
            var main_total: f32 = 0;
            var cross_max: f32 = 0;
            const count = n.children.items.len;
            for (n.children.items) |c| {
                const cs = try compute(c, lctx, inner_w, inner_h);
                if (row) {
                    main_total += cs.w;
                    cross_max = @max(cross_max, cs.h);
                } else {
                    main_total += cs.h;
                    cross_max = @max(cross_max, cs.w);
                }
            }
            if (count > 0) main_total += s.gap * @as(f32, @floatFromInt(count - 1));

            const box_w = s.width orelse (if (row)
                main_total + s.padding.horizontal() + s.border.horizontal()
            else
                cross_max + s.padding.horizontal() + s.border.horizontal());
            const box_h = s.height orelse (if (row)
                cross_max + s.padding.vertical() + s.border.vertical()
            else
                main_total + s.padding.vertical() + s.border.vertical());
            return clampSize(s, box_w, box_h);
        },
    }
}

/// Top-down placement pass.
fn arrange(n: *node.Node, lctx: LayoutContext, x: f32, y: f32, w: f32, h: f32) !void {
    const s = n.style;
    n.layout = .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .cx = x + s.padding.left + s.border.left,
        .cy = y + s.padding.top + s.border.top,
    };

    // Components forward their box to the expanded child.
    if (n.kind == .component) {
        if (n.child) |c| try arrange(c, lctx, x, y, w, h);
        return;
    }
    if (n.kind != .rect) return;

    const inner_w = @max(w - s.padding.horizontal() - s.border.horizontal(), 0);
    const inner_h = @max(h - s.padding.vertical() - s.border.vertical(), 0);
    const children = n.children.items;
    if (children.len == 0) return;

    const row = s.direction == .row;
    const main_avail = if (row) inner_w else inner_h;
    const cross_avail = if (row) inner_h else inner_w;
    const alloc = lctx.arena;

    const sizes = try alloc.alloc(Size, children.len);
    defer alloc.free(sizes);
    const main_sizes = try alloc.alloc(f32, children.len);
    defer alloc.free(main_sizes);

    var main_total: f32 = 0;
    for (children, 0..) |c, i| {
        sizes[i] = try compute(c, lctx, inner_w, inner_h);
        const basis = c.style.flex_basis orelse (if (row) sizes[i].w else sizes[i].h);
        main_sizes[i] = basis;
        main_total += basis;
    }
    if (children.len > 0) main_total += s.gap * @as(f32, @floatFromInt(children.len - 1));

    var free = main_avail - main_total;

    // Grow: distribute the surplus among flexible children.
    if (free > 0) {
        var grow_sum: f32 = 0;
        for (children) |c| grow_sum += c.style.flex_grow;
        if (grow_sum > 0) {
            for (children, 0..) |c, i| {
                if (c.style.flex_grow > 0) {
                    main_sizes[i] += free * (c.style.flex_grow / grow_sum);
                }
            }
            free = 0;
        }
    } else if (free < 0) {
        // Shrink: take the deficit back from shrinkable children, weighted by
        // shrink factor * current size.
        var shrink_sum: f32 = 0;
        for (children, 0..) |c, i| {
            shrink_sum += c.style.flex_shrink * @max(main_sizes[i], 0.0001);
        }
        if (shrink_sum > 0) {
            for (children, 0..) |c, i| {
                const weight = c.style.flex_shrink * @max(main_sizes[i], 0.0001);
                if (weight > 0) {
                    main_sizes[i] += free * (weight / shrink_sum);
                }
            }
            free = 0;
        }
    }

    // Justification along the main axis.
    var pos: f32 = 0;
    var between: f32 = s.gap;
    switch (s.justify_content) {
        .flex_start => {},
        .center => pos = @max(free, 0) / 2,
        .flex_end => pos = @max(free, 0),
        .space_between => {
            if (children.len > 1) {
                between = s.gap + @max(free, 0) / @as(f32, @floatFromInt(children.len - 1));
            }
        },
        .space_evenly => {
            const even = @max(free, 0) / @as(f32, @floatFromInt(children.len + 1));
            pos = even;
            between = s.gap + even;
        },
    }

    for (children, 0..) |c, i| {
        var ms = @max(main_sizes[i], 0);
        // Clamp the distributed main size to the child's own min/max.
        if (c.style.min_width) |v| {
            if (!row) ms = @max(ms, v);
        }
        if (c.style.max_width) |v| {
            if (!row) ms = @min(ms, v);
        }
        if (c.style.min_height) |v| {
            if (row) ms = @max(ms, v);
        }
        if (c.style.max_height) |v| {
            if (row) ms = @min(ms, v);
        }

        const measured_cross = if (row) sizes[i].h else sizes[i].w;
        const align_mode = c.style.align_self orelse s.align_items;
        var cross_size: f32 = measured_cross;
        var cross_pos: f32 = 0;
        switch (align_mode) {
            .stretch => {
                cross_size = cross_avail;
                cross_pos = 0;
            },
            .flex_start => {},
            .center => cross_pos = (cross_avail - measured_cross) / 2,
            .flex_end => cross_pos = cross_avail - measured_cross,
        }

        if (row) {
            try arrange(c, lctx, n.layout.cx + pos, n.layout.cy + cross_pos, ms, cross_size);
        } else {
            try arrange(c, lctx, n.layout.cx + cross_pos, n.layout.cy + pos, cross_size, ms);
        }
        pos += ms + between;
    }
}