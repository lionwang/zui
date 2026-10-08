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
const element = @import("../element.zig");
const skia = @import("../skia.zig");

pub const LayoutContext = struct {
    font_collection: skia.FontCollection,
    arena: std.mem.Allocator,
};

const Size = struct { w: f32, h: f32 };

/// The style a child should be laid out with. A component node is
/// transparent for layout: it forwards its box to the single element it
/// expands to, so its own (empty) style must not be the one consulted for
/// flex, alignment or clamps - otherwise a component root's `flex_grow`
/// would silently never apply.
fn nodeStyle(n: *node.Node) element.Style {
    var current = n;
    while (current.kind == .component) {
        current = current.child orelse break;
    }
    return current.style;
}

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
            // `no_wrap` lays the text out at its full intrinsic width:
            // one long line (explicit '\n' still breaks) for single-line
            // inputs and horizontally scrolling labels.
            // The intrinsic width is an estimate that is slightly *smaller*
            // than the width the laid-out line actually needs: laying the
            // paragraph out at exactly `max_intrinsic` made Skia break at
            // every opportunity (the chat time pills, measured at their own
            // intrinsic width, wrapped into two lines and overflowed their
            // 22px boxes). The slack feeds only the line breaker, and the
            // measured box is clamped back below, because `width()` reports
            // the layout constraint rather than the glyph extent.
            const slack: f32 = if (s.no_wrap) 8 else 4;
            // A box that was content-sized from this very measurement gives
            // the arrange pass `avail_w == max_intrinsic` (down to float
            // noise), so equal counts as fitting: a strict `>` would send it
            // through the wrap branch and round-wrap the line again.
            const fit = avail_w >= max_intrinsic - 0.5;
            const wrap_width = if (s.no_wrap or fit)
                max_intrinsic + slack
            else
                avail_w;
            para.layout(@max(wrap_width, 0));
            var w: f32 = para.width();
            var h: f32 = para.height();
            // `width()` is the layout constraint (max_intrinsic + slack
            // here), not the glyph extent: a paragraph that fits never
            // wraps, so its widest line is exactly the intrinsic width.
            if (fit) w = @max(max_intrinsic, 0);
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
        .shape => {
            // A shape draws in a `view x view` coordinate space scaled to the
            // element box, so its natural size is whatever the style declares
            // (24 by default, the common icon viewBox).
            const w = s.width orelse 24;
            const h = s.height orelse 24;
            return clampSize(s, w, h);
        },
        .component => {
            if (n.child) |c| return compute(c, lctx, avail_w, avail_h);
            return clampSize(s, 0, 0);
        },
        .rect => {
            // Children are measured against the space this box can *actually*
            // offer: the box's own max constraints shrink the incoming
            // available space, otherwise an auto-width bubble's text would
            // lay out at the full viewport width and then overflow the bubble.
            const eff_w = if (s.max_width) |mw| @min(avail_w, mw) else avail_w;
            const eff_h = if (s.max_height) |mh| @min(avail_h, mh) else avail_h;
            const inner_w = @max(eff_w - s.padding.horizontal() - s.border.horizontal(), 0);
            const inner_h = @max(eff_h - s.padding.vertical() - s.border.vertical(), 0);
            const row = s.direction == .row;
            const scrollable = s.scroll != null;
            var main_total: f32 = 0;
            var cross_max: f32 = 0;
            // Absolute children keep their natural size (measured with the
            // inner space) but never contribute to the flow measurement.
            var flow_count: usize = 0;
            for (n.children.items) |c| {
                const cs = try compute(c, lctx, inner_w, inner_h);
                if (nodeStyle(c).position == .absolute) continue;
                flow_count += 1;
                if (row) {
                    main_total += cs.w;
                    cross_max = @max(cross_max, cs.h);
                } else {
                    main_total += cs.h;
                    cross_max = @max(cross_max, cs.w);
                }
            }
            if (flow_count > 0) main_total += s.gap * @as(f32, @floatFromInt(flow_count - 1));

            // A scroll container reports no content along the main axis: it is
            // sized by whatever the parent allocates it and the content is
            // reached by scrolling.
            const main = if (scrollable) 0 else main_total;
            const box_w = s.width orelse (if (row)
                main + s.padding.horizontal() + s.border.horizontal()
            else
                cross_max + s.padding.horizontal() + s.border.horizontal());
            const box_h = s.height orelse (if (row)
                cross_max + s.padding.vertical() + s.border.vertical()
            else
                main + s.padding.vertical() + s.border.vertical());
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
    var flow_count: usize = 0;
    for (children, 0..) |c, i| {
        sizes[i] = try compute(c, lctx, inner_w, inner_h);
        if (nodeStyle(c).position == .absolute) continue;
        flow_count += 1;
        const basis = nodeStyle(c).flex_basis orelse (if (row) sizes[i].w else sizes[i].h);
        main_sizes[i] = basis;
        main_total += basis;
    }
    if (flow_count > 0) main_total += s.gap * @as(f32, @floatFromInt(flow_count - 1));

    var free = main_avail - main_total;

    // Scroll containers keep every child at its natural size: the content is
    // meant to overflow and be reached by scrolling, never to be squeezed
    // into the viewport.
    if (s.scroll == null) {
        // Grow: distribute the surplus among flexible children.
        if (free > 0) {
            var grow_sum: f32 = 0;
            for (children) |c| {
                if (nodeStyle(c).position == .absolute) continue;
                grow_sum += nodeStyle(c).flex_grow;
            }
            if (grow_sum > 0) {
                for (children, 0..) |c, i| {
                    if (nodeStyle(c).position == .absolute) continue;
                    const grow = nodeStyle(c).flex_grow;
                    if (grow > 0) {
                        main_sizes[i] += free * (grow / grow_sum);
                    }
                }
                free = 0;
            }
        } else if (free < 0) {
            // Shrink: take the deficit back from shrinkable children, weighted by
            // shrink factor * current size.
            var shrink_sum: f32 = 0;
            for (children, 0..) |c, i| {
                if (nodeStyle(c).position == .absolute) continue;
                shrink_sum += nodeStyle(c).flex_shrink * @max(main_sizes[i], 0.0001);
            }
            if (shrink_sum > 0) {
                for (children, 0..) |c, i| {
                    if (nodeStyle(c).position == .absolute) continue;
                    const weight = nodeStyle(c).flex_shrink * @max(main_sizes[i], 0.0001);
                    if (weight > 0) {
                        main_sizes[i] += free * (weight / shrink_sum);
                    }
                }
                free = 0;
            }
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
            if (flow_count > 1) {
                between = s.gap + @max(free, 0) / @as(f32, @floatFromInt(flow_count - 1));
            }
        },
        .space_evenly => {
            const even = @max(free, 0) / @as(f32, @floatFromInt(flow_count + 1));
            pos = even;
            between = s.gap + even;
        },
    }

    // Scroll: re-pin the offset when the anchor changed, clamp it against the
    // content extent, then shift the whole run backwards. Baking the offset
    // into the children's layout boxes keeps hit testing consistent for free.
    if (s.scroll != null) {
        if (n.scroll) |*st| {
            var content: f32 = 0;
            for (main_sizes) |ms| content += @max(ms, 0);
            if (children.len > 0) content += s.gap * @as(f32, @floatFromInt(children.len - 1));
            const pad_main = if (row) s.padding.horizontal() else s.padding.vertical();
            st.content_h = content + pad_main;
            st.viewport_h = if (row) w else h;
            if (st.spec.anchor != st.pinned_for) {
                st.offset = switch (st.spec.pin) {
                    .top => 0,
                    .bottom => st.maxOffset(),
                };
                st.pinned_for = st.spec.anchor;
            }
            const max = st.maxOffset();
            if (st.offset > max) st.offset = max;
            if (st.offset < 0) st.offset = 0;
            pos -= st.offset;
        }
    }

    for (children, 0..) |c, i| {
        if (nodeStyle(c).position == .absolute) continue;
        var ms = @max(main_sizes[i], 0);
        // Clamp the distributed main size to the child's own min/max.
        const cs = nodeStyle(c);
        if (cs.min_width) |v| {
            if (!row) ms = @max(ms, v);
        }
        if (cs.max_width) |v| {
            if (!row) ms = @min(ms, v);
        }
        if (cs.min_height) |v| {
            if (row) ms = @max(ms, v);
        }
        if (cs.max_height) |v| {
            if (row) ms = @min(ms, v);
        }

        const measured_cross = if (row) sizes[i].h else sizes[i].w;
        const align_mode = cs.align_self orelse s.align_items;
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

    // Absolute children: pinned to the content box, out of the flex flow.
    // `left`+`top` anchor them, `right`/`bottom` either stretch the box
    // (when the opposite edge is also set) or anchor that side. Inside a
    // scroll container they move with the content, like flow children.
    for (children, 0..) |c, i| {
        const cs = nodeStyle(c);
        if (cs.position != .absolute) continue;

        var cw = sizes[i].w;
        var ch = sizes[i].h;
        var ax = n.layout.cx;
        var ay = n.layout.cy;

        if (cs.left) |l| ax += l;
        if (cs.top) |t| ay += t;
        if (cs.right) |r| {
            if (cs.left != null) {
                if (cs.width == null) cw = @max(inner_w - cs.left.? - r, 0);
            } else {
                ax += inner_w - r - cw;
            }
        }
        if (cs.bottom) |b| {
            if (cs.top != null) {
                if (cs.height == null) ch = @max(inner_h - cs.top.? - b, 0);
            } else {
                ay += inner_h - b - ch;
            }
        }
        if (s.scroll != null) {
            if (n.scroll) |*st| {
                if (row) ax -= st.offset else ay -= st.offset;
            }
        }
        const clamped = clampSize(cs, cw, ch);
        try arrange(c, lctx, ax, ay, clamped.w, clamped.h);
    }
}
