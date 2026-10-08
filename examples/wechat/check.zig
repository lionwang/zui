//! Headless driver: pumps synthetic events through the window and
//! asserts the whole interaction pipeline (focus, selection, clipboard,
//! scroll, window controls, final pixels) before writing the screenshot.
//!
//! `zig build wechat -- check` runs this instead of the window.

const std = @import("std");
const zui = @import("zui");
const node_mod = zui.node;

const theme = @import("theme.zig");
const data = @import("data.zig");
const sys = data.sys;
const c = theme.c;
const icons = @import("icons.zig").icons;
const element = zui.element;

/// Byte-by-byte comparison of two static icon paths (`PathOp` is a tagged
/// union of payload structs, so `std.mem.eql` cannot compare it).
fn sameOps(a: []const element.PathOp, b: []const element.PathOp) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const tag = std.meta.activeTag(x);
        if (tag != std.meta.activeTag(y)) return false;
        switch (x) {
            .move_to => |p1| {
                const p2 = y.move_to;
                if (p1.x != p2.x or p1.y != p2.y) return false;
            },
            .line_to => |p1| {
                const p2 = y.line_to;
                if (p1.x != p2.x or p1.y != p2.y) return false;
            },
            .quad_to => |q1| {
                const q2 = y.quad_to;
                if (q1.c.x != q2.c.x or q1.c.y != q2.c.y or
                    q1.p.x != q2.p.x or q1.p.y != q2.p.y) return false;
            },
            .cubic_to => |q1| {
                const q2 = y.cubic_to;
                if (q1.c1.x != q2.c1.x or q1.c1.y != q2.c1.y or
                    q1.c2.x != q2.c2.x or q1.c2.y != q2.c2.y or
                    q1.p.x != q2.p.x or q1.p.y != q2.p.y) return false;
            },
            .rrect => |r1| {
                const r2 = y.rrect;
                if (r1.box.left != r2.box.left or r1.box.top != r2.box.top or
                    r1.box.right != r2.box.right or r1.box.bottom != r2.box.bottom or
                    r1.radius != r2.radius) return false;
            },
            .close => {},
        }
    }
    return true;
}

const app_mod = @import("app.zig");
const WeChat = app_mod.WeChat;
const chat_room = @import("chat_room.zig");

fn collectNodes(n: *node_mod.Node, list: *std.ArrayList(*node_mod.Node)) !void {
    try list.append(std.heap.page_allocator, n);
    if (n.child) |kid| try collectNodes(kid, list);
    for (n.children.items) |kid| try collectNodes(kid, list);
}

/// The first retained node matching `pred`, in tree order.
fn findNode(root: *node_mod.Node, pred: *const fn (*node_mod.Node) bool) ?*node_mod.Node {
    var nodes: std.ArrayList(*node_mod.Node) = .empty;
    defer nodes.deinit(std.heap.page_allocator);
    collectNodes(root, &nodes) catch return null;
    for (nodes.items) |n| {
        if (pred(n)) return n;
    }
    return null;
}

/// Whether any retained node currently holds exactly this text. Used for
/// the seeded timestamps, whose bytes used to dangle out of `TimeBuf.view`.
fn hasText(root: *node_mod.Node, needle: []const u8) bool {
    var nodes: std.ArrayList(*node_mod.Node) = .empty;
    defer nodes.deinit(std.heap.page_allocator);
    collectNodes(root, &nodes) catch return false;
    for (nodes.items) |n| {
        if (n.text) |t| if (std.mem.eql(u8, t, needle)) return true;
    }
    return false;
}

/// The chat input's label: a text child of the horizontally scrolling input
/// rect. The label itself may be scrolled left past the pane, so the parent
/// is what locates it.
fn isInputLabel(n: *node_mod.Node) bool {
    if (n.text == null) return false;
    const parent = n.parent orelse return false;
    return parent.scroll != null and parent.layout.y > 500 and parent.layout.x > 300;
}

/// The chat input rect itself: focusable, with the horizontal scroll.
fn isInputRect(n: *node_mod.Node) bool {
    return n.focusable and n.scroll != null and n.layout.y > 500 and n.layout.x > 300;
}

/// The 发送 button in the composer's tool row (48x26).
fn isSendButton(n: *node_mod.Node) bool {
    return n.kind == .rect and n.layout.w == 48 and n.layout.h == 26 and
        n.layout.y > 600 and (n.style.background == c.send or
        n.style.background == c.send_disabled);
}

/// The floating emoji picker layer: an absolutely positioned white panel
/// under the composer's catcher (which is absolute but background-less).
fn isPickerLayer(n: *node_mod.Node) bool {
    return n.kind == .rect and n.style.position == .absolute and
        n.style.background == c.emoji_panel and n.children.items.len > 0;
}

/// The first chat-pane text in tree order: the chat header's title (the
/// session panel lives at x < 340, and the header row is the first child of
/// the chat column, before any message).
fn isChatHeaderName(n: *node_mod.Node) bool {
    return n.text != null and n.layout.x > 290 and n.layout.y > 32;
}

/// A session-list row: the text of one of its items is matched by
/// `session_needle` (x < 340), then the walk-up finds the row rect.
var session_needle: []const u8 = "";
fn isSessionItemText(n: *node_mod.Node) bool {
    const t = n.text orelse return false;
    return n.layout.x < 340 and n.layout.y > 32 and
        std.mem.eql(u8, t, session_needle);
}

/// The clickable row of a session item: the item rect is the first ancestor
/// tall enough (64 logical px) to be the row.
fn sessionRowOf(n: *node_mod.Node) ?*node_mod.Node {
    var current: ?*node_mod.Node = n;
    while (current) |row| {
        if (row.layout.h >= 60 and row.onclick != null) return row;
        current = row.parent;
    }
    return null;
}

/// A chat message bubble text containing `msg_needle` (set at runtime, so
/// the needle lives in a global rather than the predicate itself). The chat
/// pane starts right of the session list (x > 340) and below the header
/// (y > 55); messages may sit at any scroll offset.
var msg_needle: []const u8 = "";
fn isMessageText(n: *node_mod.Node) bool {
    const t = n.text orelse return false;
    return n.layout.x > 300 and n.layout.y > 55 and
        std.mem.indexOf(u8, t, msg_needle) != null;
}

/// The session pane's search strip: the rect that holds the search pill,
/// reached from the placeholder label four levels up
/// (label -> input rect -> component -> pill -> strip).
fn stripNode(root: *node_mod.Node) ?*node_mod.Node {
    var nodes: std.ArrayList(*node_mod.Node) = .empty;
    defer nodes.deinit(std.heap.page_allocator);
    collectNodes(root, &nodes) catch return null;
    for (nodes.items) |n| {
        const t = n.text orelse continue;
        if (!std.mem.eql(u8, t, "搜索")) continue;
        const ir = n.parent orelse continue;
        const comp = ir.parent orelse continue;
        const pill = comp.parent orelse continue;
        return pill.parent;
    }
    return null;
}

/// A chat date-pill text (a time string in the message pane, not the
/// session list): used to assert it stays on a single line.
var pill_needle: []const u8 = "";
fn isPillText(n: *node_mod.Node) bool {
    const t = n.text orelse return false;
    return n.layout.x > 300 and std.mem.indexOf(u8, t, pill_needle) != null;
}

/// Count pixels inside a logical rectangle of the framebuffer that satisfy
/// `match`. The surface wraps the GL back buffer, which after `frame()` has
/// already been swapped and holds the *previous* frame - render one
/// identical extra frame first so the read is current.
fn countPixels(
    application: *zui.App,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    match: *const fn (r: u32, g: u32, b: u32) bool,
) usize {
    const fbw: i32 = @intCast(application.window.framebuffer_width);
    const fbh: i32 = @intCast(application.window.framebuffer_height);
    if (fbw == 0 or fbh == 0) return 0;
    const buf = std.heap.page_allocator.alloc(u8, @as(usize, @intCast(fbw * fbh)) * 4) catch return 0;
    defer std.heap.page_allocator.free(buf);
    if (!application.surface.readPixels(buf, fbw, fbh)) return 0;
    const width: usize = @intCast(fbw);
    const scale = width / @max(@as(usize, @intCast(application.window.width)), 1);
    const step = @max(scale, 1);
    var hits: usize = 0;
    var yy: usize = @intFromFloat(y * @as(f32, @floatFromInt(scale)));
    const y_end: usize = @intFromFloat((y + h) * @as(f32, @floatFromInt(scale)));
    while (yy < y_end) : (yy += step) {
        var xx: usize = @intFromFloat(x * @as(f32, @floatFromInt(scale)));
        const x_end: usize = @intFromFloat((x + w) * @as(f32, @floatFromInt(scale)));
        while (xx < x_end) : (xx += step) {
            const p = std.mem.bytesToValue(u32, buf[(yy * width + xx) * 4 ..][0..4]);
            if (match((p >> 16) & 0xff, (p >> 8) & 0xff, p & 0xff)) hits += 1;
        }
    }
    return hits;
}

fn isDark(r: u32, g: u32, b: u32) bool {
    return r < 110 and g < 110 and b < 110;
}

/// Neither the #FAFAFA chat surface nor the picker panel's white: actual
/// painted content (the emoji's color glyph ink).
fn isPaintedInk(r: u32, g: u32, b: u32) bool {
    return !(r >= 0xF8 and g >= 0xF8 and b >= 0xF8);
}

/// The selection highlight 0x3390C4FF blended over a white bubble gives
/// roughly (232, 224, 255): a subtle blue cast.
fn isSelectionTint(r: u32, g: u32, b: u32) bool {
    return b > 150 and b > r + 15 and b > g + 10;
}

fn countDark(application: *zui.App, x: f32, y: f32, w: f32, h: f32) usize {
    return countPixels(application, x, y, w, h, &isDark);
}

fn press(win: *zui.window.Window, x: f32, y: f32) void {
    win.queue.push(.{ .cursor_move = .{ .x = x, .y = y } });
    win.queue.push(.{ .mouse_button = .{
        .button = .left,
        .action = .press,
        .mods = .{},
        .x = x,
        .y = y,
    } });
}

fn moveTo(win: *zui.window.Window, x: f32, y: f32) void {
    win.queue.push(.{ .cursor_move = .{ .x = x, .y = y } });
}

/// A real click: move, press, release. A bare `press` leaves the button held
/// down, so a later cursor jump is read as a drag (a drag-select inside an
/// input, for example - the typed char then replaces the selection).
fn clickAt(win: *zui.window.Window, x: f32, y: f32) void {
    press(win, x, y);
    release(win, x, y);
}

fn release(win: *zui.window.Window, x: f32, y: f32) void {
    win.queue.push(.{ .mouse_button = .{
        .button = .left,
        .action = .release,
        .mods = .{},
        .x = x,
        .y = y,
    } });
}

fn keyEvent(win: *zui.window.Window, k: zui.events.Key, mods: zui.events.Modifier) void {
    win.queue.push(.{ .key = .{
        .key = k,
        .scancode = 0,
        .action = .press,
        .mods = mods,
    } });
}

fn typeText(win: *zui.window.Window, text: []const u8) void {
    var view = std.unicode.Utf8View.init(text) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        win.queue.push(.{ .char = .{ .codepoint = cp, .mods = .{} } });
    }
}

fn fail(msg: []const u8) error{RenderCheckFailed} {
    std.debug.print("CHECK FAIL: {s}\n", .{msg});
    return error.RenderCheckFailed;
}

pub fn run() !void {
    var application = try zui.App.init(std.heap.page_allocator, WeChat, {}, .{
        .title = "微信",
        .width = 1030,
        .height = 720,
        .exit_on_escape = false,
        .system_menu = false,
        .title_bar = false,
        .icon = "wechat.ico",
    });
    defer application.deinit();
    const win = application.window;

    // The app icon (title bar, Alt+Tab, taskbar - the dock equivalent) must
    // have loaded from the .ico installed next to the executable.
    if (application.window.icon == null)
        return fail("window icon was not loaded from wechat.ico");
    std.debug.print("CHECK app icon loaded ok\n", .{});

    // Let the initial tree build and settle.
    try application.frame();
    try application.frame();

    // The Windows clipboard is a shared resource: a background monitoring
    // service can hold it open for a long time, and copy/paste assertions
    // are then skipped (noted in the output) instead of failing the run.
    const clipboard_ok = !zui.skia.clipboardLocked();
    if (!clipboard_ok) std.debug.print("NOTE: clipboard locked by another process; copy/paste checks will be skipped\n", .{});

    // 0. The search pill: the magnifier sits as a *suffix* to the right of
    //    the editable field, both centered on the 26px pill. `ui.rect`
    //    defaults to a *column*: written as a rect, the two stack and the
    //    text shrinks to fit the height (icon above a squashed placeholder).
    {
        var list = std.ArrayList(*node_mod.Node).empty;
        defer list.deinit(std.heap.page_allocator);
        try collectNodes(application.root_node, &list);
        var label: ?*node_mod.Node = null;
        for (list.items) |n| {
            if (n.text) |t| if (std.mem.eql(u8, t, "搜索")) {
                label = n;
                break;
            };
        }
        const t = label orelse return fail("search placeholder missing");
        // The label lives inside the text input's own sub-tree (component ->
        // input rect -> label), so walk up to the pill row that owns both.
        const input_rect = t.parent orelse return fail("search input missing");
        const comp = input_rect.parent orelse return fail("search input component missing");
        const pill = comp.parent orelse return fail("search pill missing");
        if (pill.children.items.len != 2) return fail("search pill has unexpected children");
        const field = pill.children.items[0];
        const icon = pill.children.items[1];
        if (icon.kind != .shape) return fail("search suffix icon missing");
        if (field.layout.x + field.layout.w > icon.layout.x)
            return fail("search icon is not a suffix");
        if (t.layout.h < 15) return fail("search placeholder is vertically squashed");
        const icon_cy = icon.layout.y + icon.layout.h / 2;
        const text_cy = t.layout.y + t.layout.h / 2;
        if (@abs(icon_cy - text_cy) > 2)
            return fail("search icon and placeholder are misaligned");
        std.debug.print("CHECK search pill: suffix icon + field aligned ok\n", .{});
    }

    // 0b. The chat header and the session pane's search strip (`c.top_strip`)
    //     occupy the same vertical band, so the message list and the session
    //     list both start at the same y.
    {
        const header_name = findNode(application.root_node, isChatHeaderName) orelse
            return fail("chat header name missing");
        const header_row = header_name.parent orelse
            return fail("chat header row missing");
        const strip = stripNode(application.root_node) orelse
            return fail("search strip missing");
        const strip_bottom = strip.layout.y + strip.layout.h;
        const header_bottom = header_row.layout.y + header_row.layout.h;
        if (@abs(strip_bottom - header_bottom) > 0.5)
            return fail("chat header is not aligned with the search strip");
        std.debug.print("CHECK chat header aligned with search strip ok\n", .{});
    }

    // 0c. The cursor follows the hovered element - and falls back to the
    //     default arrow when nothing under the cursor declares a shape.
    //     Without that fallback an I-beam leaks out of the text input into
    //     the title bar's drag area, and the window drag started from it
    //     then shows a text caret instead of an arrow.
    {
        moveTo(win, 700, 651); // the composer's input
        try application.frame();
        if (win.cursor_shape != .ibeam)
            return fail("cursor over the input is not the I-beam");
        // A message bubble declares the I-beam too, so hovering its text
        // shows the caret before any click (and the drag then selects it).
        msg_needle = "网页版微信已上线";
        {
            const msg = findNode(application.root_node, isMessageText) orelse
                return fail("seeded message missing");
            moveTo(win, msg.layout.x + 24, msg.layout.y + 9);
            try application.frame();
            if (win.cursor_shape != .ibeam)
                return fail("cursor over a message bubble is not the I-beam");
        }
        moveTo(win, 500, 16); // the title bar's drag area
        try application.frame();
        if (win.cursor_shape != .arrow)
            return fail("cursor over the title bar did not fall back to the arrow");
        moveTo(win, 310, 110); // the message list's background
        try application.frame();
        if (win.cursor_shape != .arrow)
            return fail("cursor over the chat surface did not fall back to the arrow");
        std.debug.print("CHECK cursor: I-beam over input and messages, arrow fallback ok\n", .{});
    }

    // 1. Autofocus: the input must accept typing without being clicked.
    //    (The default session is 文件传输助手。)
    {
        const header = findNode(application.root_node, isChatHeaderName) orelse
            return fail("chat header missing");
        if (!std.mem.eql(u8, header.text.?, "文件传输助手"))
            return fail("unexpected initial session");
    }
    typeText(win, "abc你好");
    try application.frame();
    {
        const label = findNode(application.root_node, isInputLabel) orelse
            return fail("input label missing after typing");
        if (!std.mem.eql(u8, label.text.?, "abc你好"))
            return fail("autofocus typing did not reach the input");
        std.debug.print("CHECK autofocus typing: content reached the input ok\n", .{});
    }

    // 1b. The search field is not autofocused (the chat input is the primary
    //     target), but clicking it must move the focus so typing flows in;
    //     clicking the chat input then brings the focus back.
    {
        var nodes: std.ArrayList(*node_mod.Node) = .empty;
        defer nodes.deinit(std.heap.page_allocator);
        try collectNodes(application.root_node, &nodes);
        var field: ?*node_mod.Node = null;
        for (nodes.items) |n| {
            if (n.focusable and n.layout.x < 340 and n.layout.y > 33 and n.layout.y < 73) {
                field = n;
                break;
            }
        }
        const sf = field orelse return fail("search field missing");
        clickAt(win, sf.layout.x + 30, sf.layout.y + sf.layout.h / 2);
        try application.frame();
        // The placeholder is a hint for the idle field: it must vanish as
        // soon as the field is focused, while the buffer is still empty.
        if (hasText(application.root_node, "搜索"))
            return fail("search placeholder did not disappear on focus");
        // Clicking somewhere else (dead space in the message list) must drop
        // the focus again - the placeholder comes back while it is empty
        // and the caret disappears (it used to keep blinking: `caret_on`
        // alone is just the blink phase, not the focus).
        clickAt(win, 500, 400);
        try application.frame();
        if (!hasText(application.root_node, "搜索"))
            return fail("search field did not lose focus on outside click");
        {
            // `sf` is the input rect itself; its children are the label and
            // the caret (a ~1.5px bar while it is shown).
            for (sf.children.items) |kid| {
                if (kid.layout.w > 0.5 and kid.layout.w < 2.5 and kid.layout.h > 12)
                    return fail("search field still shows a caret after losing focus");
            }
        }
        clickAt(win, sf.layout.x + 30, sf.layout.y + sf.layout.h / 2);
        try application.frame();
        typeText(win, "查找");
        try application.frame();
        if (!hasText(application.root_node, "查找"))
            return fail("typing did not reach the search field after clicking it");
        const chat_input = findNode(application.root_node, isInputRect) orelse
            return fail("chat input missing");
        // Click past the text so the caret lands at its end.
        clickAt(win, chat_input.layout.x + chat_input.layout.w - 30, chat_input.layout.y + 20);
        try application.frame();
        // The chat composer is sticky: dead-space clicks may not interrupt
        // its typing (a session row click is covered by step 3 + 6).
        clickAt(win, 500, 400);
        try application.frame();
        typeText(win, "续");
        try application.frame();
        if (!hasText(application.root_node, "abc你好续"))
            return fail("chat input lost focus on a dead-space click");
        keyEvent(win, .backspace, .{});
        try application.frame();
        std.debug.print("CHECK search field takes focus on click ok\n", .{});
    }

    // 2. The typed text must actually paint: glyph ink inside the label box.
    try application.frame();
    {
        const label = findNode(application.root_node, isInputLabel) orelse
            return fail("input label missing for the paint probe");
        const dark = countDark(
            &application,
            label.layout.x,
            label.layout.y,
            label.layout.w,
            label.layout.h,
        );
        if (dark < 40) {
            std.debug.print("CHECK FAIL: typed text did not paint (dark={d})\n", .{dark});
            return error.RenderCheckFailed;
        }
        std.debug.print("CHECK typed text paints: {d} ink pixels ok\n", .{dark});
    }

    // 2b. The seeded timestamps must render as real text: `TimeBuf.view`
    //     used to take `self` by value, so every time slice pointed at a
    //     dead stack copy and painted zeroed/garbled bytes of the right
    //     length instead of "10:12" / "昨天 21:18".
    if (!hasText(application.root_node, "10:12"))
        return fail("session list time text missing (TimeBuf.view regression)");
    if (!hasText(application.root_node, "昨天 21:18"))
        return fail("chat date pill text missing (TimeBuf.view regression)");
    // The pill text must stay a single line: laying the paragraph out at
    // its (marginally underestimated) intrinsic width used to round-wrap
    // it into two lines that overflowed the 22px pill.
    pill_needle = "昨天 21:18";
    {
        const pill = findNode(application.root_node, isPillText) orelse
            return fail("date pill node missing");
        const para = pill.paragraph orelse
            return fail("date pill paragraph missing");
        if (para.lineCount() != 1)
            return fail("date pill text wrapped instead of one line");
        if (pill.layout.h > 20)
            return fail("date pill text is taller than one line");
        if (pill.parent == null or pill.parent.?.layout.h != 22)
            return fail("date pill box height is not 22");
    }
    std.debug.print("CHECK seeded timestamps render as text ok\n", .{});

    // 2c. 李娜's 动画表情 message renders as the real emoji inline, at the
    //     same height as regular message text - not as the literal string
    //     "[动画表情]", and not as an oversized glyph.
    {
        session_needle = "李娜";
        const item_text = findNode(application.root_node, isSessionItemText) orelse
            return fail("李娜 session row missing");
        const row = sessionRowOf(item_text) orelse
            return fail("李娜 session row rect missing");
        press(win, row.layout.x + row.layout.w / 2, row.layout.y + row.layout.h / 2);
        try application.frame();
        {
            const header = findNode(application.root_node, isChatHeaderName) orelse
                return fail("chat header missing for the emoji session");
            if (!std.mem.eql(u8, header.text.?, "李娜"))
                return fail("session switch to 李娜 did not change the header");
        }
        if (hasText(application.root_node, "[动画表情]"))
            return fail("the emoji message still shows the literal placeholder");
        var nodes: std.ArrayList(*node_mod.Node) = .empty;
        defer nodes.deinit(std.heap.page_allocator);
        try collectNodes(application.root_node, &nodes);
        var emoji_msg: ?*node_mod.Node = null;
        for (nodes.items) |n| {
            if (n.text) |t| {
                if (std.mem.eql(u8, t, "🤣") and n.layout.x > 300) emoji_msg = n;
            }
        }
        const s = emoji_msg orelse return fail("the emoji message did not render");
        // Text height, not a big sticker glyph: the bubble's body text is
        // 14px at a 1.45 line height (~20px), so the label must sit in
        // that band.
        if (s.style.font_size > 16 or s.layout.h > 30)
            return fail("the message emoji is larger than the surrounding text");
        // ...and it must paint its color_glyph (a broken font fallback would
        // leave advance space and no ink).
        try application.frame();
        const colored = countPixels(
            &application,
            s.layout.x,
            s.layout.y,
            s.layout.w,
            s.layout.h,
            &isPaintedInk,
        );
        if (colored < 40) return fail("the message emoji did not paint its color glyph");
        std.debug.print("CHECK message emoji renders inline at text size ok\n", .{});
    }

    // 3. Switch to the second session (张伟) by clicking its row in the
    //    session list.
    {
        session_needle = "张伟";
        const item_text = findNode(application.root_node, isSessionItemText) orelse
            return fail("session item missing");
        const row = sessionRowOf(item_text) orelse
            return fail("session row missing");
        press(win, row.layout.x + row.layout.w / 2, row.layout.y + row.layout.h / 2);
    }
    try application.frame();
    {
        const header = findNode(application.root_node, isChatHeaderName) orelse
            return fail("chat header missing after session switch");
        if (!std.mem.eql(u8, header.text.?, "张伟"))
            return fail("session switch did not change the header");
        if (!hasText(application.root_node, "昨天 22:14"))
            return fail("switched chat date pill text missing");
        std.debug.print("CHECK session switch: 张伟 ok\n", .{});
    }

    // 4. Message text selection: drag across a received bubble selects a
    //    range of glyphs, and Ctrl+C copies that slice to the clipboard.
    msg_needle = "同意，到时候听你的安排";
    const msg = findNode(application.root_node, isMessageText) orelse
        return fail("seeded message missing");
    {
        const x0 = msg.layout.x + 24;
        const x1 = msg.layout.x + 180;
        const my = msg.layout.y + 9;
        // A synthetic drag is a press, a move and a release in three
        // successive event polls; a slow frame can land the glyph anchor on
        // a stale paragraph layout and leave the selection empty, so the
        // gesture is retried once before it fails.
        var sel: ?@TypeOf(msg.style.selection.?) = null;
        var attempt: u8 = 0;
        while (attempt < 2 and sel == null) : (attempt += 1) {
            press(win, x0, my);
            try application.frame();
            moveTo(win, x1, my);
            try application.frame();
            release(win, x1, my);
            try application.frame();
            sel = msg.style.selection;
        }
        const s = sel orelse
            return fail("drag did not select message text");
        if (s.start == s.end)
            return fail("message selection is empty");
        const para = msg.paragraph orelse return fail("message has no paragraph");
        var boxes: [16]f32 = undefined;
        const rect_count = para.rectsForRange(s.start, s.end, &boxes);
        if (rect_count < 1)
            return fail("selection produces no highlight rects");
        // The highlight covers whole line boxes, not tight glyph bounds: one
        // line of 14px text at 1.45 spacing is ~20px tall.
        const rect_h = boxes[3] - boxes[1];
        // The highlight covers whole line boxes, not tight glyph bounds: one
        // line of 14px text at 1.45 spacing is ~20px tall.
        if (rect_h < 19.5) {
            std.debug.print("RECTX box=({d:.1},{d:.1},{d:.1},{d:.1})\n", .{ boxes[0], boxes[1], boxes[2], boxes[3] });
            return fail("selection rect height does not cover the line box");
        }
        std.debug.print("CHECK message selection: {d}..{d} {d} rects h={d:.1} ok\n", .{ s.start, s.end, rect_count, rect_h });
    }
    {
        // The highlight must actually paint: tinted pixels across the label.
        try application.frame();
        const tinted = countPixels(
            &application,
            msg.layout.x,
            msg.layout.y,
            msg.layout.w,
            msg.layout.h,
            &isSelectionTint,
        );
        if (tinted < 20)
            return fail("selection highlight did not paint");
        std.debug.print("CHECK selection highlight paints: {d} tinted pixels ok\n", .{tinted});
    }

    // 4b. The bubble tails (nubs): each beak's base is flush against its
    //     bubble's edge and its center sits at the bubble's vertical middle
    //     (the reference's tails are mid-height, not at the corner).
    {
        var nodes: std.ArrayList(*node_mod.Node) = .empty;
        defer nodes.deinit(std.heap.page_allocator);
        try collectNodes(application.root_node, &nodes);
        var checked: usize = 0;
        for (nodes.items) |n| {
            if (n.shape_ops == null) continue;
            const left = sameOps(n.shape_ops.?, &chat_room.nub_left);
            const right = sameOps(n.shape_ops.?, &chat_room.nub_right);
            if (!left and !right) continue;
            // The beak box stretches to the bubble's height; its sibling in
            // the shared gap-0 row is the bubble itself.
            const nub_box = n.parent orelse return fail("nub box missing");
            const nested = nub_box.parent orelse return fail("nub row missing");
            const sibling = if (nested.children.items[0] == nub_box)
                nested.children.items[1]
            else
                nested.children.items[0];
            const flush_edge: f32 = if (left)
                nub_box.layout.x + nub_box.layout.w
            else
                nub_box.layout.x;
            const bubble_edge: f32 = if (left)
                sibling.layout.x
            else
                sibling.layout.x + sibling.layout.w;
            if (@abs(flush_edge - bubble_edge) > 0.5)
                return fail("the bubble tail does not touch its bubble");
            const shape_c = n.layout.y + n.layout.h / 2;
            const bubble_c = sibling.layout.y + sibling.layout.h / 2;
            if (@abs(shape_c - bubble_c) > 2)
                return fail("the bubble tail is not centered on the bubble");
            checked += 1;
        }
        if (checked < 2)
            return fail("bubble tails missing");
        std.debug.print("CHECK bubble tails flush + centered ok ({d})\n", .{checked});
    }
    {
        // Ctrl+C copies the slice to the clipboard. The clipboard can be
        // held open by another process for a long time, in which case the
        // copy is skipped rather than failing the run.
        if (clipboard_ok) {
            keyEvent(win, .c, .{ .control = true });
            try application.frame();
            var clip: [256]u8 = undefined;
            const got = zui.skia.clipboardGetText(&clip);
            if (got.len == 0 or std.mem.indexOf(u8, msg.text.?, got) == null)
                return fail("Ctrl+C did not copy a slice of the message");
            std.debug.print("CHECK message copy: clipboard is a substring ok\n", .{});
        } else {
            std.debug.print("CHECK message copy: SKIPPED (clipboard locked)\n", .{});
        }
    }

    // 5. Clicking the input clears the selection and moves the focus back.
    {
        const input = findNode(application.root_node, isInputRect) orelse
            return fail("input rect missing");
        press(win, input.layout.x + input.layout.w / 2, input.layout.y + input.layout.h / 2);
        try application.frame();
        if (msg.style.selection != null)
            return fail("click did not clear the message selection");
        std.debug.print("CHECK click clears message selection ok\n", .{});
    }

    // 5b. The custom title bar buttons work: the middle button toggles the
    //     window between maximized and restored, and pressing chrome (which
    //     is not focusable) must not steal the keyboard focus - the input
    //     keeps typing afterward.
    {
        var nodes: std.ArrayList(*node_mod.Node) = .empty;
        defer nodes.deinit(std.heap.page_allocator);
        try collectNodes(application.root_node, &nodes);
        var buttons: [3]?*node_mod.Node = .{ null, null, null };
        var found: usize = 0;
        for (nodes.items) |n| {
            if (n.onclick != null and n.layout.y == 0 and n.layout.h == 32) {
                if (found < 3) buttons[found] = n;
                found += 1;
            }
        }
        if (found != 3) return fail("custom title bar buttons missing");
        const max_button = buttons[1].?;
        const before_w = application.window.width;
        const before_h = application.window.height;
        press(win, max_button.layout.x + max_button.layout.w / 2, max_button.layout.h / 2);
        try application.frame();
        try application.frame();
        if (!application.window.maximized())
            return fail("the title bar maximize button did not maximize");
        // Not just the attribute: the window geometry must really change.
        if (application.window.width == before_w and application.window.height == before_h)
            return fail("maximize did not resize the window");
        std.debug.print("CHECK window maximized: {d}x{d} ok\n", .{
            application.window.width, application.window.height,
        });
        press(win, max_button.layout.x + max_button.layout.w / 2, max_button.layout.h / 2);
        try application.frame();
        try application.frame();
        if (application.window.maximized())
            return fail("the title bar maximize button did not restore");
        if (application.window.width != before_w or application.window.height != before_h)
            return fail("restore did not bring the window back to its size");
        std.debug.print("CHECK window restored: {d}x{d} ok\n", .{
            application.window.width, application.window.height,
        });
        std.debug.print("CHECK custom title bar buttons: maximize/restore ok\n", .{});
    }

    // 6. Input editing: the content stays one unwrapped line; select-all,
    //    copy, delete and paste round-trip the whole buffer.
    const tail = "输入框文字横向排版测试";
    for (0..6) |_| typeText(win, tail);
    try application.frame();
    {
        var expected: [512]u8 = undefined;
        var want_len: usize = 0;
        const typed_head = "abc你好";
        @memcpy(expected[want_len .. want_len + typed_head.len], typed_head);
        want_len += typed_head.len;
        for (0..6) |_| {
            @memcpy(expected[want_len .. want_len + tail.len], tail);
            want_len += tail.len;
        }
        const want = expected[0..want_len];

        const label = findNode(application.root_node, isInputLabel) orelse
            return fail("input label missing for the layout check");
        const para = label.paragraph orelse return fail("input has no paragraph");
        if (para.lineCount() != 1)
            return fail("input text wrapped instead of scrolling");
        if (label.layout.w < para.width() - 1)
            return fail("input label was clipped by its box instead of overflowing");

        // Ctrl+A selects everything; Ctrl+C / Ctrl+V round-trip the whole
        // buffer through the clipboard, and Backspace deletes the selection
        // as a unit. The copy/paste steps need the clipboard; the select and
        // delete steps do not.
        keyEvent(win, .a, .{ .control = true });
        try application.frame();
        if (label.style.selection == null)
            return fail("Ctrl+A did not select the input content");
        if (clipboard_ok) {
            // The clipboard is shared with the rest of the system: a
            // background monitor can echo a copy back with formatting of
            // its own, so a mismatch is retried once before it fails.
            var copied = false;
            var attempt: u8 = 0;
            while (attempt < 2 and !copied) : (attempt += 1) {
                keyEvent(win, .c, .{ .control = true });
                try application.frame();
                var clip: [512]u8 = undefined;
                const got = zui.skia.clipboardGetText(&clip);
                if (std.mem.eql(u8, got, want)) copied = true;
            }
            if (!copied)
                return fail("Ctrl+A/C did not copy the whole input");
        }
        keyEvent(win, .backspace, .{});
        try application.frame();
        if (label.text.?.len != 0)
            return fail("Backspace did not delete the selection");
        if (clipboard_ok) {
            keyEvent(win, .v, .{ .control = true });
            try application.frame();
            if (!std.mem.eql(u8, label.text.?, want))
                return fail("Ctrl+V did not restore the buffer");
            // Leave the input empty for the send below.
            keyEvent(win, .a, .{ .control = true });
            try application.frame();
            keyEvent(win, .backspace, .{});
            try application.frame();
            if (label.text.?.len != 0)
                return fail("input was not empty after the delete");
        }
        if (clipboard_ok) {
            std.debug.print("CHECK input editing: single line + select/copy/paste ok\n", .{});
        } else {
            std.debug.print("CHECK input editing: single line + select/delete ok (copy/paste SKIPPED: clipboard locked)\n", .{});
        }
    }

    // 6b. The smiley in the composer's tool row opens the emoji picker.
    //     Picking a cell appends the emoji to the composer buffer and
    //     closes the panel; clicking anywhere else closes it too.
    {
        var nodes: std.ArrayList(*node_mod.Node) = .empty;
        defer nodes.deinit(std.heap.page_allocator);
        try collectNodes(application.root_node, &nodes);
        var smiley: ?*node_mod.Node = null;
        for (nodes.items) |n| {
            if (n.shape_ops) |ops| {
                if (sameOps(ops, &icons.smile_line)) smiley = n;
            }
        }
        const first = smiley orelse return fail("emoji tool button missing");
        const btn = first.parent orelse return fail("emoji tool button wrapper missing");
        clickAt(win, btn.layout.x + btn.layout.w / 2, btn.layout.y + btn.layout.h / 2);
        try application.frame();
        const layer = findNode(application.root_node, isPickerLayer) orelse
            return fail("emoji picker did not open");
        // The framebuffer readback lags one frame (the GL back buffer after a
        // swap shows the previous frame): render an identical extra frame so
        // the pixel probes below see the picker.
        try application.frame();
        // The panel paints white over the chat surface, and its cells carry
        // the emoji of the grid (they render as color glyphs, so the ink
        // count is not a reliable signal here - the panel color is).
        const panel_px = countPixels(
            &application,
            layer.layout.x + 3,
            layer.layout.y + 3,
            layer.layout.w - 6,
            layer.layout.h - 6,
            &isPaintedInk,
        );
        if (panel_px < 5000) return fail("emoji picker panel did not paint");
        nodes.clearRetainingCapacity();
        try collectNodes(application.root_node, &nodes);
        const needle = chat_room.emoji_grid[chat_room.emoji_grid.len - 1];
        var cell_text: ?*node_mod.Node = null;
        for (nodes.items) |n| {
            if (n.text) |t| {
                if (std.mem.eql(u8, t, needle)) cell_text = n;
            }
        }
        const ct = cell_text orelse return fail("emoji picker grid is missing its cells");
        const cell = ct.parent orelse return fail("emoji picker cell missing");
        // The emoji must render as an actual color glyph: DirectWrite
        // fallback resolves Segoe UI Emoji for codepoints Microsoft YaHei
        // lacks; if that broke, the cell would hold advance space and no ink.
        const glyph_px = countPixels(
            &application,
            cell.layout.x,
            cell.layout.y,
            cell.layout.w,
            cell.layout.h,
            &isPaintedInk,
        );
        if (glyph_px < 30) return fail("emoji glyph did not render in the picker cell");
        clickAt(win, cell.layout.x + cell.layout.w / 2, cell.layout.y + cell.layout.h / 2);
        try application.frame();
        {
            const label = findNode(application.root_node, isInputLabel) orelse
                return fail("input label missing after picking an emoji");
            if (std.mem.indexOf(u8, label.text.?, needle) == null)
                return fail("picking an emoji did not append it to the composer");
        }
        if (findNode(application.root_node, isPickerLayer) != null)
            return fail("emoji picker did not close after picking");

        // Reopen, then click dead space in the message list: the catcher
        // under the composer must close the panel. The tree reshaped when
        // the picker closed, so the button is looked up again - retained
        // nodes may move while reconciling the flattened children list.
        nodes.clearRetainingCapacity();
        try collectNodes(application.root_node, &nodes);
        var smiley2: ?*node_mod.Node = null;
        for (nodes.items) |n| {
            if (n.shape_ops) |ops| {
                if (sameOps(ops, &icons.smile_line)) smiley2 = n;
            }
        }
        const s2 = smiley2 orelse return fail("emoji tool button missing on reopen");
        const btn2 = s2.parent orelse return fail("emoji tool button wrapper missing on reopen");
        clickAt(win, btn2.layout.x + btn2.layout.w / 2, btn2.layout.y + btn2.layout.h / 2);
        try application.frame();
        if (findNode(application.root_node, isPickerLayer) == null)
            return fail("emoji picker did not reopen");
        clickAt(win, 500, 400);
        try application.frame();
        if (findNode(application.root_node, isPickerLayer) != null)
            return fail("emoji picker did not close on an outside click");

        // Clear the buffer so the send test below starts from empty.
        const ci = findNode(application.root_node, isInputRect) orelse
            return fail("chat input missing");
        clickAt(win, ci.layout.x + ci.layout.w / 2, ci.layout.y + ci.layout.h / 2);
        try application.frame();
        keyEvent(win, .a, .{ .control = true });
        try application.frame();
        keyEvent(win, .backspace, .{});
        try application.frame();
        std.debug.print("CHECK emoji picker opens, inserts, closes ok\n", .{});
    }

    // 7. Type the real message and send it.
    const message = "你好，这是用 zui 写的聊天界面";
    typeText(win, message);
    keyEvent(win, .enter, .{});
    try application.frame();
    try application.frame();

    // Wait for the simulated reply (1.4 s) to land, then render it.
    sys.sleep(1700);
    try application.frame();
    try application.frame();
    {
        msg_needle = "用 zui 写的聊天界面";
        _ = findNode(application.root_node, isMessageText) orelse
            return fail("the sent message did not land in the list");
        msg_needle = "嗯嗯，知道了";
        _ = findNode(application.root_node, isMessageText) orelse
            return fail("the simulated reply did not land");
        std.debug.print("CHECK send + simulated reply land ok\n", .{});
    }

    // One wheel notch up: the offset shrinks away from the pinned bottom
    // (the list travels down, older messages come into view).
    scrollMessageList(application.root_node, win, 1);
    try application.frame();
    try application.frame();
    {
        const st = messageListScroll(application.root_node) orelse
            return fail("message list scroll state missing");
        if (st.offset <= 0 or st.offset >= st.maxOffset())
            return fail("scrolling up did not move the list off the bottom pin");
        std.debug.print("CHECK message list scrolls up: offset={d:.1}/{d:.1} ok\n", .{ st.offset, st.maxOffset() });
    }

    // The scrollbar thumb is draggable: pressing it (rather than the message
    // under it), dragging and releasing must move the offset to where the
    // thumb was dropped - here back to the middle of the track - and a plain
    // click afterwards must still reach the message rows (the drag leaves no
    // capture residue). The thumb geometry mirrors `paintScrollbar`.
    {
        const n = messageListNode(application.root_node) orelse
            return fail("message list scroll node missing");
        const st = n.scroll orelse return fail("message list scroll state missing");
        const max = st.maxOffset();
        if (max <= 0) return fail("message list does not overflow");
        const b = n.bounds();
        const fraction = b.height() / st.content_h;
        const thumb_h = @max(b.height() * fraction, 24);
        const track_h = b.height() - thumb_h;
        const start_top = b.top + track_h * (st.offset / max);
        press(win, b.right - 3, start_top + thumb_h / 2);
        try application.frame();
        const mid_y = b.top + track_h / 2 + thumb_h / 2;
        win.queue.push(.{ .cursor_move = .{ .x = b.right - 3, .y = mid_y } });
        try application.frame();
        try application.frame();
        {
            const after = messageListScroll(application.root_node) orelse
                return fail("message list scroll state missing after drag");
            const want = max * ((mid_y - thumb_h / 2) - b.top) / track_h;
            if (@abs(after.offset - want) > max * 0.05)
                return fail("dragging the thumb did not scroll to the drop point");
            std.debug.print("CHECK scrollbar thumb drags to {d:.1}/{d:.1} ok\n", .{ after.offset, max });
        }
        // Drag on to the bottom of the track so the wheel test below starts
        // from the pinned bottom again.
        const bottom_y = b.top + track_h + thumb_h / 2;
        win.queue.push(.{ .cursor_move = .{ .x = b.right - 3, .y = bottom_y } });
        try application.frame();
        try application.frame();
        {
            const after = messageListScroll(application.root_node) orelse
                return fail("message list scroll state missing after drag");
            if (@abs(after.offset - after.maxOffset()) > 0.5)
                return fail("dragging the thumb to the bottom did not re-pin the list");
        }
        release(win, b.right - 3, bottom_y);
        try application.frame();
    }

    // Scrolling back down returns the list to the bottom pin, which is where
    // the final frame is captured.
    scrollMessageList(application.root_node, win, -2);
    try application.frame();
    {
        const st = messageListScroll(application.root_node) orelse
            return fail("message list scroll state missing");
        if (st.offset != st.maxOffset())
            return fail("scrolling back down did not re-pin the list");
        std.debug.print("CHECK scroll re-pin: offset={d:.1}/{d:.1} ok\n", .{ st.offset, st.maxOffset() });
    }

    // 9. The composer: a tall editor under a 2px #EAEAEA rule with the
    //    tool row at the bottom (line icons + send). It used to be a
    //    borderless one-line strip whose input area simply was not there.
    {
        const ir = findNode(application.root_node, isInputRect) orelse
            return fail("chat input missing");
        if (ir.layout.h < 60)
            return fail("the composer editor is not the tall input area");
        // The input is wrapped by the `textInput` component node; the panel
        // is the bordered rect above it.
        var panel: ?*node_mod.Node = ir.parent;
        while (panel) |p| {
            if (p.kind == .rect and p.style.border.top == 2 and
                p.style.border_color == c.composer_border) break;
            panel = p.parent;
        }
        const p = panel orelse return fail("composer panel missing");
        if (p.layout.h != c.composer_h)
            return fail("composer panel height is not 130px");

        var nodes: std.ArrayList(*node_mod.Node) = .empty;
        defer nodes.deinit(std.heap.page_allocator);
        try collectNodes(application.root_node, &nodes);
        var emoji: ?*node_mod.Node = null;
        for (nodes.items) |n| {
            if (n.shape_ops) |ops| {
                if (sameOps(ops, &icons.smile_line)) emoji = n;
            }
        }
        const e = emoji orelse return fail("composer emoji icon missing");
        if (e.shape_fill or e.style.background != c.toolbar_icon)
            return fail("composer emoji icon is not a stroked line icon");
        // The tool row sits at the bottom of the card: below the editor,
        // whose height is composer_h minus the row, the 6px bottom inset
        // and the 2px bottom border.
        if (e.layout.w < 15 or e.layout.h < 15 or
            e.layout.y < p.layout.y + c.composer_h - c.toolbar_h - 8)
        {
            return fail("composer emoji icon is not in the tool row");
        }
        std.debug.print("CHECK composer: editor {d:.0}px tall, emoji line icon in the tool row ok\n", .{ir.layout.h});
    }
    // 10. The caret blinks WeChat green over the dark typed text. It is only
    //     painted in its visible phase, so sample frames until it shows.
    {
        const ir = findNode(application.root_node, isInputRect) orelse
            return fail("chat input missing");
        var saw_caret = false;
        var tries: usize = 0;
        while (!saw_caret and tries < 12) : (tries += 1) {
            // Sample inside a *visible* half of the blink cycle (the caret
            // is on during the even 530ms windows): waiting out an odd
            // window first keeps the loop from aliasing onto the dark
            // phase when frames are slow.
            const now = zui.skia.millis();
            const phase = @divFloor(now, 530);
            if (@mod(phase, 2) != 0)
                sys.sleep(@intCast((phase + 1) * 530 - now + 20));
            try application.frame();
            for (ir.children.items) |kid| {
                // The caret is a ~1.5px rect; the label is a text node
                // (empty while no buffer, w 0 but tall - not the caret).
                if (kid.kind == .rect and kid.layout.w > 0.5 and kid.layout.w < 2.5 and
                    kid.layout.h > 12)
                {
                    if (kid.style.background != c.caret)
                        return fail("the caret is not WeChat green");
                    saw_caret = true;
                    break;
                }
            }
            if (!saw_caret) sys.sleep(150);
        }
        if (!saw_caret) return fail("the caret never appears in the focused composer");
        std.debug.print("CHECK caret blinks WeChat green ok\n", .{});
    }

    application.config.exit_after_frames = 1;
    application.config.on_final_frame = onFinalFrame;
    {
        // The sent-message bubble: walk up from its text to the green rect.
        msg_needle = "用 zui 写的聊天界面";
        const sent_label = findNode(application.root_node, isMessageText) orelse
            return fail("sent message missing for the final probe");
        var current: ?*node_mod.Node = sent_label;
        while (current) |el| {
            if (el.kind == .rect and el.style.background == c.bubble_me) {
                sent_bubble = el;
                break;
            }
            current = el.parent;
        }
        if (sent_bubble == null) return fail("sent message bubble (green) missing");
    }
    // The buffer was emptied by the send, so the tree's own send button must
    // be in its disabled state - a definitive read next to the pixel probe.
    {
        const btn = findNode(application.root_node, isSendButton) orelse
            return fail("send button missing before the final probe");
        send_button_node = btn;
        if (btn.style.background != c.send_disabled) {
            const lbl = findNode(application.root_node, isInputLabel);
            const lbl_text: []const u8 = if (lbl) |l| (l.text orelse "") else "<none>";
            std.debug.print(
                "DBG send button bg=0x{X} enabled; input label='{s}' len={d}\n",
                .{ btn.style.background, lbl_text, lbl_text.len },
            );
            return fail("the send button is not disabled after the send");
        }
    }
    try application.frame();

    if (!result_ok) return error.RenderCheckFailed;
    std.debug.print("RENDER_OK: {s}\n", .{result_msg});
}
fn scrollMessageList(root: *node_mod.Node, win: *zui.window.Window, notches: i32) void {
    var found: ?*node_mod.Node = null;
    var nodes: std.ArrayList(*node_mod.Node) = .empty;
    defer nodes.deinit(std.heap.page_allocator);
    collectNodes(root, &nodes) catch return;
    for (nodes.items) |n| {
        if (n.scroll != null and n.layout.x > 290 and n.layout.h > 300) {
            found = n;
            break;
        }
    }
    const n = found orelse return;
    const x = n.layout.x + n.layout.w / 2;
    const y = n.layout.y + n.layout.h / 2;
    win.queue.push(.{ .cursor_move = .{ .x = x, .y = y } });
    // One wheel notch of y = +1 moves the content down: the offset shrinks
    // and older messages come into view.
    const dir: f32 = if (notches > 0) 1 else -1;
    const count: u32 = @intCast(if (notches > 0) notches else -notches);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        win.queue.push(.{ .scroll = .{ .x = 0, .y = dir } });
    }
}

/// The message list scroll state: (offset, max) so the check can assert the
/// offset is clamped to its extent rather than a magic number.
fn messageListScroll(root: *node_mod.Node) ?node_mod.ScrollState {
    if (messageListNode(root)) |n| return n.scroll;
    return null;
}

/// The message list's scroll container itself (geometry for the thumb test).
fn messageListNode(root: *node_mod.Node) ?*node_mod.Node {
    var nodes: std.ArrayList(*node_mod.Node) = .empty;
    defer nodes.deinit(std.heap.page_allocator);
    collectNodes(root, &nodes) catch return null;
    for (nodes.items) |n| {
        if (n.scroll != null and n.layout.x > 290 and n.layout.h > 300) {
            return n;
        }
    }
    return null;
}

fn messageListOffset(root: *node_mod.Node) f32 {
    return if (messageListScroll(root)) |st| st.offset else 0;
}

var result_ok = false;
var result_msg: []const u8 = "no frame captured";

/// The sent-message bubble, located in the last framed tree so the final
/// pixel probe does not depend on where it landed.
var sent_bubble: ?*node_mod.Node = null;

/// The send button, likewise, so the final probe can log the tree's own
/// state alongside the pixel read when they disagree (a rare flake).
var send_button_node: ?*node_mod.Node = null;

fn onFinalFrame(buf: []const u8, w: i32, h: i32) void {
    const width: usize = @intCast(w);
    const height: usize = @intCast(h);
    const n = width * height;
    var content: usize = 0;
    var green: usize = 0; // sent bubbles
    var white: usize = 0; // received bubbles / panels
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const px = std.mem.bytesToValue(u32, buf[i * 4 ..][0..4]);
        if (px == c.chat_bg) continue; // chat background
        content += 1;
        const r = (px >> 16) & 0xff;
        const g = (px >> 8) & 0xff;
        if (g > 180 and r < 180) green += 1; // #9DF29F (bubble) and #07C160 (send)
        if (px == c.bubble_other) white += 1; // #EEEFF1 received bubbles
    }
    std.debug.print("RENDER_STATS content={d}/{d} green={d} white={d}\n", .{ content, n, green, white });

    // Point checks against the expected layout. The custom title bar sits
    // at the top of the right column (`AppConfig.title_bar = false`, the
    // WeChat root renders it inside its tree), so the rail next to it runs
    // the full window height and the session list / chat start at y = 32.
    // The pixel expectations mirror the WeChat 4.0 reference screenshot,
    // sampled value by value: mica-ish rail, #EEEef0 pane, #FAFAFA chat
    // surface, sent bubble #9DF29F. Coordinates are for the 58px rail /
    // 240px pane layout.
    const checks = [_]struct { x: usize, y: usize, want: u32, name: []const u8 }{
        .{ .x = 10, .y = 300, .want = 0xFFCFCFCF, .name = "nav rail (mica gray)" },
        .{ .x = 10, .y = 8, .want = 0xFFCFCFCF, .name = "nav rail full height" },
        // Below the last session item: the plain pane background.
        .{ .x = 120, .y = 690, .want = 0xFFEEEFF1, .name = "session panel background" },
        // Item 1 (张伟, selected): the empty strip above its avatar/text.
        .{ .x = 150, .y = 150, .want = 0xFFE3E3E4, .name = "selected session (张伟)" },
        .{ .x = 310, .y = 110, .want = 0xFFFAFAFA, .name = "message list edge (chat bg)" },
        // The tool menu (in-tree title bar, the rail's mica color) and the
        // chat header below it (#FAFAFA + 1px #F0F0F0 divider inside).
        .{ .x = 700, .y = 16, .want = 0xFFCFCFCF, .name = "tool menu (in-tree title bar)" },
        .{ .x = 700, .y = 55, .want = 0xFFFAFAFA, .name = "chat header background" },
        .{ .x = 700, .y = 79, .want = 0xFFF0F0F0, .name = "chat header divider" },
        // The composer card: a floating rounded panel inset 6/8px from the
        // chat column, 132px tall, stopped 3px short of the window bottom
        // (y 585..717). Its #EAEAEA border is 2px top/bottom, 1px sides;
        // the editor surface and the 6px bottom inset are #FAFAFA.
        .{ .x = 700, .y = 585, .want = 0xFFEAEAEA, .name = "composer card top border" },
        .{ .x = 700, .y = 716, .want = 0xFFEAEAEA, .name = "composer card bottom border" },
        .{ .x = 304, .y = 647, .want = 0xFFEAEAEA, .name = "composer card left border" },
        .{ .x = 700, .y = 651, .want = 0xFFFAFAFA, .name = "composer editor surface" },
        .{ .x = 700, .y = 711, .want = 0xFFFAFAFA, .name = "composer card bottom inset" },
        // The 3px strip between the card and the window edge: the shadow
        // halo reaches into it (#F4F4F4, ~2% over the chat bg).
        .{ .x = 700, .y = 719, .want = 0xFFF4F4F4, .name = "gap under the composer card" },
        // The buffer was emptied by the send, so the button is disabled.
        // Probed right of the 发送 glyphs so the probe does not clip a
        // glyph's anti-aliased edge.
        .{ .x = 1005, .y = 695, .want = 0xFFEDEDED, .name = "send button (disabled after send)" },
    };
    var failures: usize = 0;
    for (checks) |chk| {
        const px = std.mem.bytesToValue(u32, buf[(chk.y * width + chk.x) * 4 ..][0..4]);
        const ok = px == chk.want;
        if (!ok) failures += 1;
        std.debug.print("CHECK {s}: got=0x{X} want=0x{X} {s}\n", .{ chk.name, px, chk.want, if (ok) "ok" else "FAIL" });
        if (!ok and std.mem.eql(u8, chk.name, "send button (disabled after send)")) {
            // A rare flake: log the tree's own button state next to the
            // pixel read to see which side disagreed.
            if (send_button_node) |b| {
                std.debug.print("DBG send-button tree bg=0x{X} at ({d:.0},{d:.0})\n", .{ b.style.background, b.layout.x, b.layout.y });
            } else {
                std.debug.print("DBG send-button node not found in the tree\n", .{});
            }
        }
    }
    if (green < 2000) failures += 1;
    if (white < 200) failures += 1; // at least one received bubble painted

    // The sent-message bubble lands wherever the list is pinned to; probe a
    // point inside its padding rather than a fixed screen coordinate.
    if (sent_bubble) |b| {
        const px_x: usize = @intFromFloat(b.layout.x + 5);
        const px_y: usize = @intFromFloat(b.layout.y + 5);
        const px = std.mem.bytesToValue(u32, buf[(px_y * width + px_x) * 4 ..][0..4]);
        const ok = px == c.bubble_me;
        if (!ok) failures += 1;
        std.debug.print("CHECK sent message bubble: got=0x{X} want=0x{X} {s}\n", .{ px, c.bubble_me, if (ok) "ok" else "FAIL" });
    } else {
        failures += 1;
        std.debug.print("CHECK sent message bubble: node missing FAIL\n", .{});
    }

    if (!zui.skia.encodePng(buf, w, h, "screenshot_wechat.png")) {
        result_ok = false;
        result_msg = "png write failed";
        return;
    }
    if (failures > 0) {
        result_ok = false;
        result_msg = "layout checks failed";
        return;
    }
    result_ok = true;
    result_msg = "chat window rendered";
}
