//! Input and render check: drives the counter UI programmatically (no mouse
//! needed), verifies hover/click delivery and live resizing, and reads the
//! framebuffer back to confirm content was drawn.

const std = @import("std");
const zui = @import("zui");
const ui = zui.widgets;
const Context = zui.Context;
const Element = zui.Element;
const node_mod = zui.node;
const events = zui.events;

pub const Counter = struct {
    pub const Props = void;

    pub fn render(ctx: *Context, props: Props) Element {
        _ = props;

        var count = ctx.useState(i32, 0);

        return ui.column(ctx, .{
            .style = .{
                .padding = .all(24),
                .gap = 16,
                .background = 0xFF1E1E2E,
                .align_items = .center,
                .justify_content = .center,
                .flex_grow = 1,
            },
            .children = &.{
                ui.text(.{
                    .color = 0xFF89B4FA,
                    .font_size = 18,
                    .font_weight = .semibold,
                }, "zui counter"),
                ui.text(.{
                    .color = 0xFFEAEAEA,
                    .font_size = 56,
                    .font_weight = .bold,
                    .line_height = 1.1,
                }, std.fmt.allocPrint(ctx.arena, "{d}", .{count.get()}) catch "<err>"),
                ui.row(ctx, .{
                    .style = .{ .gap = 12 },
                    .children = &.{
                        ui.button(ctx, .{
                            .label = "- 1",
                            .style = .{ .background = 0xFF6C7086 },
                            .onclick = count.handler(struct {
                                fn dec(p: *i32) void {
                                    p.* -= 1;
                                }
                            }.dec),
                        }),
                        ui.button(ctx, .{
                            .label = "+ 1",
                            .style = .{ .background = 0xFF89B4FA },
                            .onclick = count.handler(struct {
                                fn inc(p: *i32) void {
                                    p.* += 1;
                                }
                            }.inc),
                        }),
                    },
                }),
                ui.text(.{
                    .color = 0xFF6C7086,
                    .font_size = 13,
                }, "press Escape to quit"),
            },
        });
    }
};

/// Recursively collect every node in the retained tree.
fn collect(n: *node_mod.Node, list: *std.ArrayList(*node_mod.Node)) !void {
    try list.append(std.heap.page_allocator, n);
    if (n.child) |c| try collect(c, list);
    for (n.children.items) |c| try collect(c, list);
}

pub fn main() !void {
    var application = try zui.App.init(std.heap.page_allocator, Counter, {}, .{
        .title = "zui render check",
        .width = 640,
        .height = 480,
        .exit_after_frames = 0,
        .on_final_frame = null,
    });
    defer application.deinit();

    // Let the initial tree build and settle.
    try application.frame();

    const win = application.window;
    std.debug.print("WIN size={d}x{d} fb={d}x{d} scale={d:.3}\n", .{
        win.width, win.height, win.framebuffer_width, win.framebuffer_height, win.contentScale(),
    });

    // Find the buttons and the counter text in the retained tree.
    var nodes: std.ArrayList(*node_mod.Node) = .empty;
    defer nodes.deinit(std.heap.page_allocator);
    try collect(application.root_node, &nodes);

    var buttons: [2]*node_mod.Node = undefined;
    var btn_count: usize = 0;
    var count_node: ?*node_mod.Node = null;
    for (nodes.items) |n| switch (n.kind) {
        .rect => if (n.onclick != null) {
            if (btn_count < 2) buttons[btn_count] = n;
            btn_count += 1;
        },
        .text => {
            if (n.text) |t| {
                if (std.fmt.parseInt(i32, t, 10)) |v| {
                    if (v == 0) count_node = n;
                } else |_| {}
            }
        },
        else => {},
    };
    if (btn_count != 2 or count_node == null) {
        std.debug.print("FAIL: could not find buttons/count in the tree\n", .{});
        return error.SetupFailed;
    }

    // buttons[0] is "- 1", buttons[1] is "+ 1".
    const plus = buttons[1];
    std.debug.print("PLUS button bounds L={d:.0} T={d:.0} R={d:.0} B={d:.0}\n", .{
        plus.layout.x, plus.layout.y, plus.layout.x + plus.layout.w, plus.layout.y + plus.layout.h,
    });
    const cx = plus.layout.x + plus.layout.w / 2;
    const cy = plus.layout.y + plus.layout.h / 2;

    // ---- hover: moving over the button must switch to the hand cursor ----
    win.queue.push(.{ .cursor_move = .{ .x = cx, .y = cy } });
    try application.frame();
    const hand_created = win.cursors[@intFromEnum(zui.window.CursorShape.hand)] != null;
    std.debug.print("HOVER hand_cursor={}\n", .{hand_created});
    if (!hand_created) {
        std.debug.print("HOVER_FAIL: cursor did not change over the button\n", .{});
        return error.HoverFailed;
    }

    // ---- click: the state must mutate and the text re-render ----
    win.queue.push(.{ .mouse_button = .{
        .button = .left,
        .action = .press,
        .mods = .{},
        .x = cx,
        .y = cy,
    } });
    try application.frame();

    if (count_node.?.text) |t| {
        std.debug.print("CLICK count_after={s}\n", .{t});
        if (std.mem.eql(u8, t, "1")) {
            std.debug.print("CLICK_OK\n", .{});
        } else {
            std.debug.print("CLICK_FAIL: expected 1 got {s}\n", .{t});
            return error.ClickFailed;
        }
    } else {
        std.debug.print("CLICK_FAIL: no text\n", .{});
        return error.ClickFailed;
    }

    // ---- live resize: the surface must follow and content must redraw ----
    const sizes = [_]struct { w: u32, h: u32 }{
        .{ .w = 700, .h = 520 },
        .{ .w = 500, .h = 400 },
        .{ .w = 1000, .h = 750 },
    };
    for (sizes) |s| {
        win.setSize(s.w, s.h);
        try application.frame();
    }

    std.debug.print("RESIZE final fb={d}x{d}\n", .{ win.framebuffer_width, win.framebuffer_height });

    // ---- final frame readback at the new size ----
    application.config.exit_after_frames = 1;
    application.config.on_final_frame = onFrame;
    try application.frame();

    if (!result_ok) {
        std.debug.print("RENDER_FAIL: {s}\n", .{result_msg});
        return error.RenderCheckFailed;
    }
    std.debug.print("RENDER_OK: {s}\n", .{result_msg});
}

/// kN32 pixels read back as 0xAARRGGBB on a little-endian machine; classify
/// each pixel against the palette the counter example uses.
fn onFrame(buf: []const u8, w: i32, h: i32) void {
    const n = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
    var content: usize = 0;
    var blue_button: usize = 0;
    var gray_button: usize = 0;
    var light_text: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const px = std.mem.bytesToValue(u32, buf[i * 4 ..][0..4]);
        if (px == 0xFF1E1E2E) continue; // background
        content += 1;
        const r = (px >> 16) & 0xff;
        const g = (px >> 8) & 0xff;
        const b = px & 0xff;
        if (b > 0xE0 and g > 0xA0 and g < 0xC0 and r > 0x70 and r < 0xA0) {
            blue_button += 1; // #89B4FA (title text and the +1 button)
        } else if (r > 0x55 and r < 0x80 and g > 0x60 and g < 0x80 and b > 0x75 and b < 0x95) {
            gray_button += 1; // #6C7086 (the -1 button)
        } else if (r > 0xB0 and g > 0xB0 and b > 0xB0) {
            light_text += 1; // #EAEAEA / white labels
        }
    }
    std.debug.print("RENDER_STATS content={d}/{d} blue={d} gray={d} text={d}\n", .{ content, n, blue_button, gray_button, light_text });
    // Keep a PNG of the rendered frame for the README.
    if (!zui.skia.encodePng(buf, w, h, "screenshot.png")) {
        std.debug.print("PNG_FAIL: could not write screenshot.png\n", .{});
    } else {
        std.debug.print("PNG_OK: wrote screenshot.png ({d}x{d})\n", .{ w, h });
    }    if (content < 500) {
        result_ok = false;
        result_msg = "too little content drawn";
        return;
    }
    if (blue_button < 100 or gray_button < 100 or light_text < 100) {
        result_ok = false;
        result_msg = "expected buttons and text in the framebuffer";
        return;
    }
    result_ok = true;
    result_msg = "content+buttons+text present";
}

var result_ok = false;
var result_msg: []const u8 = "no frame captured";