//! Vector icon glyphs and path helpers.
//!
//! Icons are `PathOp` slices authored in a 24 x 24 coordinate space (the
//! common icon viewBox), so they scale to any size through `ui.shape`.
//! Filled icons use closed polylines; stroked ones are open strokes.
//!
//! ```zig
//! ui.shape(ctx, .{ .style = .{ .width = 16, .height = 16, .background = t.muted_foreground }, .ops = ui.icons.check, .fill = false })
//! ```

const std = @import("std");
const element = @import("../element.zig");

/// A point on a circle of radius `r` around (`cx`, `cy`) at angle `a`
/// (radians; growing angles sweep clockwise on screen, y grows downward).
fn circlePoint(cx: f32, cy: f32, r: f32, a: f32) element.Point {
    return .{ .x = cx + r * @cos(a), .y = cy + r * @sin(a) };
}

/// The check mark.
pub const check = [_]element.PathOp{
    .{ .move_to = .{ .x = 5, .y = 13 } },
    .{ .line_to = .{ .x = 10, .y = 18 } },
    .{ .line_to = .{ .x = 19, .y = 6 } },
};

/// A cross.
pub const x_mark = [_]element.PathOp{
    .{ .move_to = .{ .x = 6, .y = 6 } },
    .{ .line_to = .{ .x = 18, .y = 18 } },
    .{ .move_to = .{ .x = 18, .y = 6 } },
    .{ .line_to = .{ .x = 6, .y = 18 } },
};

pub const chevron_down = [_]element.PathOp{
    .{ .move_to = .{ .x = 6, .y = 9 } },
    .{ .line_to = .{ .x = 12, .y = 15 } },
    .{ .line_to = .{ .x = 18, .y = 9 } },
};

pub const chevron_right = [_]element.PathOp{
    .{ .move_to = .{ .x = 9, .y = 6 } },
    .{ .line_to = .{ .x = 15, .y = 12 } },
    .{ .line_to = .{ .x = 9, .y = 18 } },
};

pub const chevron_up = [_]element.PathOp{
    .{ .move_to = .{ .x = 6, .y = 15 } },
    .{ .line_to = .{ .x = 12, .y = 9 } },
    .{ .line_to = .{ .x = 18, .y = 15 } },
};

pub const minus = [_]element.PathOp{
    .{ .rrect = .{ .box = .{ .left = 5.5, .top = 11, .right = 18.5, .bottom = 13 }, .radius = 1 } },
};

pub const plus = [_]element.PathOp{
    .{ .rrect = .{ .box = .{ .left = 5.5, .top = 11, .right = 18.5, .bottom = 13 }, .radius = 1 } },
    .{ .rrect = .{ .box = .{ .left = 11, .top = 5.5, .right = 13, .bottom = 18.5 }, .radius = 1 } },
};

/// A five-pointed star.
pub const star = [_]element.PathOp{
    .{ .move_to = .{ .x = 12, .y = 2.8 } },
    .{ .line_to = .{ .x = 14.9, .y = 9.2 } },
    .{ .line_to = .{ .x = 21.9, .y = 10.0 } },
    .{ .line_to = .{ .x = 16.7, .y = 14.8 } },
    .{ .line_to = .{ .x = 18.1, .y = 21.6 } },
    .{ .line_to = .{ .x = 12, .y = 18.1 } },
    .{ .line_to = .{ .x = 5.9, .y = 21.6 } },
    .{ .line_to = .{ .x = 7.3, .y = 14.8 } },
    .{ .line_to = .{ .x = 2.1, .y = 10.0 } },
    .{ .line_to = .{ .x = 9.1, .y = 9.2 } },
    .{ .close = {} },
};

/// A small solid triangle pointing down (dropdown triggers).
pub const caret_down = [_]element.PathOp{
    .{ .move_to = .{ .x = 6, .y = 9 } },
    .{ .line_to = .{ .x = 18, .y = 9 } },
    .{ .line_to = .{ .x = 12, .y = 15.5 } },
    .{ .close = {} },
};

/// A wide arrow pointing up-in-a-tray (the upload glyph), for file inputs.
pub const inbox = [_]element.PathOp{
    .{ .move_to = .{ .x = 4, .y = 14 } },
    .{ .line_to = .{ .x = 4, .y = 19 } },
    .{ .line_to = .{ .x = 20, .y = 19 } },
    .{ .line_to = .{ .x = 20, .y = 14 } },
    .{ .move_to = .{ .x = 12, .y = 15 } },
    .{ .line_to = .{ .x = 12, .y = 4 } },
    .{ .move_to = .{ .x = 8, .y = 8 } },
    .{ .line_to = .{ .x = 12, .y = 4 } },
    .{ .line_to = .{ .x = 16, .y = 8 } },
};

/// A circle (radio outlines, avatars) as four cubic segments; kappa is the
/// standard Bezier circle constant `r * 0.5523`.
pub fn circleOps(arena: std.mem.Allocator, cx: f32, cy: f32, r: f32) ![]element.PathOp {
    return arcOps(arena, cx, cy, r, 0, 360);
}

/// An arc of a circle as cubic Bezier segments, for spinners and circular
/// progress meters. `start_deg` / `sweep_deg` follow screen coordinates
/// (positive angles go clockwise because y grows downward).
pub fn arcOps(
    arena: std.mem.Allocator,
    cx: f32,
    cy: f32,
    r: f32,
    start_deg: f32,
    sweep_deg: f32,
) ![]element.PathOp {
    const sweep = if (sweep_deg >= 360) 359.999 else if (sweep_deg <= -360) -359.999 else sweep_deg;
    const seg_count: usize = @intFromFloat(@ceil(@abs(sweep) / 90));
    if (seg_count == 0) return &.{};

    var ops = try arena.alloc(element.PathOp, seg_count + 1);
    const step = sweep / @as(f32, @floatFromInt(seg_count));

    // Standard circle-arc-to-Bezier: for a segment spanning `span`, the
    // control points sit on the tangents at distance k = 4/3 * tan(span/4) * r.
    var a = std.math.degreesToRadians(start_deg);
    ops[0] = .{ .move_to = circlePoint(cx, cy, r, a) };
    var i: usize = 0;
    while (i < seg_count) : (i += 1) {
        const b = a + std.math.degreesToRadians(step);
        const span = b - a;
        const k = r * (4.0 / 3.0) * @tan(span / 4);
        const p0 = circlePoint(cx, cy, r, a);
        const p3 = circlePoint(cx, cy, r, b);
        ops[i + 1] = .{ .cubic_to = .{
            .c1 = .{ .x = p0.x - k * @sin(a), .y = p0.y + k * @cos(a) },
            .c2 = .{ .x = p3.x + k * @sin(b), .y = p3.y - k * @cos(b) },
            .p = p3,
        } };
        a = b;
    }
    return ops;
}
