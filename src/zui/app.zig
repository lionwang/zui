//! The application runtime: owns the window, the Skia context and the retained
//! element tree, and drives the per-frame pipeline:
//!
//!   poll events -> build virtual DOM -> reconcile -> layout -> paint -> flush
//!
//! This is Freya's event loop layer (winit + dioxus + the renderer) collapsed
//! into one small loop.

const std = @import("std");
const element = @import("element.zig");
const context_mod = @import("context.zig");
const node = @import("node.zig");
const reconcile = @import("reconcile.zig");
const layout = @import("layout/layout.zig");
const paint = @import("paint.zig");
const window_mod = @import("window.zig");
const skia = @import("skia.zig");
const events = @import("events.zig");
const widgets = @import("widgets/widgets.zig");

const glfw = @import("glfw");

/// Configuration for `App.init`.
pub const AppConfig = struct {
    title: []const u8 = "zui app",
    width: u32 = 800,
    height: u32 = 600,
    background: u32 = 0xFF1E1E2E,
    /// Close the window when Escape is pressed.
    exit_on_escape: bool = true,
    /// Keep the native window chrome (title bar + system menu with its
    /// minimize / maximize / close buttons). False makes the window
    /// frameless and `App` renders a custom title bar instead - drag it,
    /// double-click to maximize, use its window buttons (see
    /// `Window.Config.system_menu`).
    system_menu: bool = true,
    /// Render the built-in custom title bar for frameless windows (still
    /// drawn full width at the top). Set it false to keep the chrome inside
    /// your component tree instead - e.g. a title bar to the right of a
    /// full-height sidebar, as WeChat does. Components reach the window
    /// through `ctx.window` then.
    title_bar: bool = true,
    /// Height of the custom title bar when `system_menu` is false.
    title_bar_height: f32 = 32,
    /// Background of the custom title bar; usually the color of the content
    /// it floats over, so the bar blends in.
    title_bar_color: u32 = 0xFFF3F3F3,
    /// UTF-8 path to an .ico file (embed a 16 and a 32 px size in it) to use
    /// as the app icon: the window's title-bar icon, Alt+Tab and the taskbar
    /// (Windows' equivalent of a dock icon) all take it. Windows only.
    icon: ?[]const u8 = null,
    /// If > 0, exit after this many frames (used by automated render checks).
    exit_after_frames: u32 = 0,
    /// Called with a copy of the framebuffer (RGBA, top-to-bottom) on the
    /// final frame, when exit_after_frames is set.
    on_final_frame: ?*const fn ([]const u8, i32, i32) void = null,
};

/// The props type of the root component (`void` when it declares none).
fn RootProps(comptime Root: type) type {
    return if (@hasDecl(Root, "Props")) Root.Props else void;
}

/// The render entry point generated for the root component.
fn rootRender(comptime Root: type) *const fn (*anyopaque, *anyopaque) element.Element {
    const Props = RootProps(Root);
    return struct {
        fn run(ctx: *anyopaque, p: *anyopaque) element.Element {
            const typed: *context_mod.Context = @as(*context_mod.Context, @ptrCast(@alignCast(ctx)));
            return Root.render(typed, @as(*Props, @ptrCast(@alignCast(p))).*);
        }
    }.run;
}

pub const App = struct {
    allocator: std.mem.Allocator,
    config: AppConfig,
    window: *window_mod.Window,
    skia_ctx: skia.Context,
    surface: skia.Surface,
    font_collection: skia.FontCollection,
    fill_paint: skia.Paint,
    stroke_paint: skia.Paint,
    root_node: *node.Node,
    /// Size the Skia surface was created for, in framebuffer pixels.
    surface_w: i32 = 0,
    surface_h: i32 = 0,
    root_props: *anyopaque,
    root_render: *const fn (*anyopaque, *anyopaque) element.Element,
    cursor_x: f32 = 0,
    cursor_y: f32 = 0,
    hover_node: ?*node.Node = null,
    /// Owner of the keyboard focus (the element that receives char / key
    /// events), set by clicking a focusable element.
    focus_node: ?*node.Node = null,
    /// True between a left press and its release.
    left_down: bool = false,
    /// The element that captured the press (nearest ancestor with an
    /// `onmouse` handler); it receives the whole press/drag/release run.
    press_target: ?*node.Node = null,
    /// A scrollbar thumb being dragged: the scroll container it belongs to
    /// and where inside the thumb the press landed, so that point stays
    /// under the cursor for the whole gesture.
    scroll_drag: ?ScrollDrag = null,
    frame_count: u32 = 0,

    /// State of a scrollbar thumb drag.
    pub const ScrollDrag = struct {
        node: *node.Node,
        grab_y: f32,
    };

    /// Create an application whose root component is `Root`.
    ///
    /// `Root` is a struct with:
    ///   * an optional `pub const Props = ...` (defaults to `void`)
    ///   * `pub fn render(ctx: *Context, props: Props) Element`
    pub fn init(
        allocator: std.mem.Allocator,
        comptime Root: type,
        args: RootProps(Root),
        config: AppConfig,
    ) !App {
        const Props = RootProps(Root);
        // Zig's entry point does not run the MSVC CRT startup, so replay the
        // parts Skia depends on (onexit table + static initializers) first.
        skia.initCrt();

        const win = try window_mod.Window.init(allocator, .{
            .title = config.title,
            .width = config.width,
            .height = config.height,
            .system_menu = config.system_menu,
            .icon = config.icon,
        });
        errdefer win.deinit(allocator);

        var skia_ctx = try skia.Context.createGl();
        errdefer skia_ctx.destroy();

        const fb_w: i32 = @intCast(win.framebuffer_width);
        const fb_h: i32 = @intCast(win.framebuffer_height);
        var surface = try skia.Surface.wrapGl(skia_ctx, fb_w, fb_h, 0, 0, 0);
        errdefer surface.destroy();

        const surface_w: i32 = fb_w;
        const surface_h: i32 = fb_h;

        var fc = try skia.FontCollection.create();
        errdefer fc.destroy();

        var fill_paint = try skia.Paint.create();
        errdefer fill_paint.destroy();
        fill_paint.setAntiAlias(true);

        var stroke_paint = try skia.Paint.create();
        errdefer stroke_paint.destroy();
        stroke_paint.setAntiAlias(true);

        const root_node = try allocator.create(node.Node);
        root_node.* = .{ .allocator = allocator, .kind = .rect };
        errdefer root_node.destroy();

        const props_box = try allocator.create(Props);
        props_box.* = args;

        return .{
            .allocator = allocator,
            .config = config,
            .window = win,
            .skia_ctx = skia_ctx,
            .surface = surface,
            .surface_w = surface_w,
            .surface_h = surface_h,
            .font_collection = fc,
            .fill_paint = fill_paint,
            .stroke_paint = stroke_paint,
            .root_node = root_node,
            .root_props = props_box,
            .root_render = rootRender(Root),
        };
    }

    pub fn deinit(self: *App) void {
        const alloc = self.allocator;
        self.root_node.destroy();
        self.stroke_paint.destroy();
        self.fill_paint.destroy();
        self.font_collection.destroy();
        self.surface.destroy();
        self.skia_ctx.destroy();
        self.window.deinit(alloc);
    }

    /// Run until the window is closed.
    pub fn run(self: *App) !void {
        // Repaint immediately when GLFW asks (Win32 repaints during its modal
        // move/size loop, where pollEvents does not return until the drag ends).
        self.window.setRefreshCallback(@ptrCast(self), refreshThunk);
        while (!self.window.shouldClose()) {
            try self.frame();
        }
    }

    fn refreshThunk(user: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(user));
        self.present() catch {};
    }

    /// Poll input and render a single frame. `run` calls this in a loop;
    /// it is public so applications with custom event loops can drive it.
    pub fn frame(self: *App) !void {
        // ---- events ---------------------------------------------------
        //
        // Note: clicks are dispatched against the retained tree from the
        // previous frame, which is exactly what is on screen right now.
        for (self.window.pollEvents()) |event| {
            switch (event) {
                .resize => {}, // handled in present() by comparing sizes
                .key => |k| {
                    if (self.config.exit_on_escape and k.key == .escape and k.action == .press) {
                        self.window.requestClose();
                    }
                    if (k.action == .press or k.action == .repeat) {
                        if (self.focusValid()) |n| {
                            if (n.onkey) |h| h.func(h.data, &k);
                        }
                    }
                },
                .char => |c| {
                    if (self.focusValid()) |n| {
                        if (n.onchar) |h| h.func(h.data, &c);
                    }
                },
                .cursor_move => |c| {
                    self.cursor_x = c.x;
                    self.cursor_y = c.y;
                    if (self.scroll_drag != null) {
                        self.moveScrollDrag(c.y);
                        continue;
                    }
                    if (self.left_down) self.dispatchMouse(.{ .x = c.x, .y = c.y, .action = .move, .button = .left });
                },
                .mouse_button => |mb| {
                    if (mb.button != .left) continue;
                    switch (mb.action) {
                        .press => {
                            self.left_down = true;
                            // A press on a scrollbar thumb begins a thumb
                            // drag instead of a click, so neither the click
                            // handlers nor the mouse capture see it.
                            if (self.beginScrollDrag(mb.x, mb.y)) continue;
                            self.dispatchClick(mb.x, mb.y);
                            self.dispatchMouse(.{ .x = mb.x, .y = mb.y, .action = .press, .button = .left });
                        },
                        .release => {
                            self.left_down = false;
                            self.scroll_drag = null;
                            self.dispatchMouse(.{ .x = mb.x, .y = mb.y, .action = .release, .button = .left });
                            self.press_target = null;
                        },
                        else => {},
                    }
                },
                .scroll => |sc| {
                    self.dispatchScroll(sc.y);
                },
                else => {},
            }
        }

        // Widgets read the live cursor while rendering (chart tooltips), so
        // the position the event loop last saw must reach the window before
        // the tree is built, including injected (synthetic) cursor moves.
        self.window.cursor_x = self.cursor_x;
        self.window.cursor_y = self.cursor_y;
        try self.present();
    }

    /// Render one frame: re-create the surface when the window was resized,
    /// reconcile the fresh element tree and paint it.
    fn present(self: *App) !void {
        // ---- surface ---------------------------------------------------
        const fb_w = self.window.framebuffer_width;
        const fb_h = self.window.framebuffer_height;
        if (fb_w == 0 or fb_h == 0) return; // minimized
        if (fb_w != self.surface_w or fb_h != self.surface_h) {
            self.surface.destroy();
            self.surface = try skia.Surface.wrapGl(
                self.skia_ctx,
                @intCast(fb_w),
                @intCast(fb_h),
                0,
                0,
                0,
            );
            self.surface_w = @intCast(fb_w);
            self.surface_h = @intCast(fb_h);
        }

        // ---- build + reconcile ---------------------------------------
        // The root component is wrapped in a viewport-sized rect so that
        // children using `flex_grow` can fill the window.
        const scale = self.window.contentScale();
        const fw: f32 = @as(f32, @floatFromInt(self.window.framebuffer_width)) / scale;
        const fh: f32 = @as(f32, @floatFromInt(self.window.framebuffer_height)) / scale;

        var frame_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer frame_arena.deinit();
        const arena = frame_arena.allocator();

        const root_component: element.Element = .{ .component = .{
            .name = "root",
            .render = self.root_render,
            .props = self.root_props,
        } };
        // A frameless window gets the custom title bar above the root
        // component unless the app opted out to render its own chrome inside
        // the component tree; the wrapper is fixed-size so the root can
        // `flex_grow`.
        const builtin_bar = !self.config.system_menu and self.config.title_bar;
        const root_children: []const element.Element = if (!builtin_bar)
            &.{root_component}
        else blk: {
            const bar = widgets.titleBarElement(arena, .{
                .window = self.window,
                .height = self.config.title_bar_height,
                .background = self.config.title_bar_color,
            });
            const children = try arena.alloc(element.Element, 2);
            children[0] = bar;
            children[1] = root_component;
            break :blk children;
        };
        const root_el: element.Element = .{ .rect = .{
            .style = .{ .width = fw, .height = fh },
            .children = root_children,
        } };
        // `self.window` is null in the pure layout tests.
        _ = try reconcile.reconcile(self.allocator, arena, self.root_node, root_el, self.window);

        // ---- layout ---------------------------------------------------
        try layout.layout(self.root_node, .{
            .font_collection = self.font_collection,
            .arena = arena,
        }, fw, fh);

        // ---- focus -----------------------------------------------------
        // Nothing focused yet (or the focused node left the tree): hand the
        // focus to the first element that asked for it (an input that should
        // accept typing right away, a modal scrim that owns the keys while
        // the dialog is open).
        if (self.focusValid() == null) {
            self.setFocus(findAutofocus(self.root_node));
        }

        // ---- hover -----------------------------------------------------
        self.updateHover();

        // ---- paint ----------------------------------------------------
        const canvas = self.surface.canvas();
        canvas.clear(self.config.background);

        var pctx: paint.PaintContext = .{
            .canvas = canvas,
            .font_collection = self.font_collection,
            .arena = arena,
            .fill = self.fill_paint,
            .stroke = self.stroke_paint,
        };
        try paint.paint(&pctx, self.root_node);

        self.surface.flushAndSubmit();

        if (self.config.exit_after_frames > 0) {
            self.frame_count += 1;
            if (self.frame_count == self.config.exit_after_frames) {
                if (self.config.on_final_frame) |cb| {
                    self.captureFrame(cb);
                }
                self.window.requestClose();
            }
        }

        self.window.swapBuffers();
    }

    /// Read the whole framebuffer back and hand it to cb. Reading from the
    /// GPU-backed surface can be denied for a frame (still-pending GL work),
    /// so the read is retried after a flush.
    fn captureFrame(self: *App, cb: *const fn ([]const u8, i32, i32) void) void {
        const w: i32 = @intCast(self.window.framebuffer_width);
        h: {
            const h: i32 = @intCast(self.window.framebuffer_height);
            if (w == 0 or h == 0) break :h;
            const buf = self.allocator.alloc(u8, @as(usize, @intCast(w * h)) * 4) catch return;
            defer self.allocator.free(buf);
            var tries: u8 = 0;
            while (tries < 5) : (tries += 1) {
                if (self.surface.readPixels(buf, w, h)) {
                    cb(buf, w, h);
                    break;
                }
                self.surface.flushAndSubmit();
            }
        }
    }

    /// Deliver a click to the deepest node under the cursor, bubbling up to
    /// every ancestor that also has a click handler. The nearest focusable
    /// ancestor takes the keyboard focus (or none, when the click is outside
    /// every focusable element).
    fn dispatchClick(self: *App, x: f32, y: f32) void {
        // A new press invalidates every text selection made so far.
        widgets.click_generation += 1;
        // The focus moves to the nearest focusable ancestor of the hit - but
        // only when there is one. With no focusable target the press blurs a
        // regular field: a search box clicked by mistake should lose the
        // focus (and show its placeholder again) once the user clicks
        // elsewhere. A *sticky* input is exempt: a chat composer must keep
        // accepting typing while the user clicks sessions, messages and
        // window chrome around it.
        var focus: ?*node.Node = null;
        var current = hitTest(self.root_node, x, y);
        while (current) |n| {
            if (focus == null and n.focusable) focus = n;
            if (n.onclick) |h| h.func(h.data);
            current = n.parent;
        }
        if (focus != null) {
            self.setFocus(focus);
            return;
        }
        if (self.focusValid()) |cur| if (cur.focus_sticky) return;
        self.setFocus(null);
    }

    /// Move the focus (and the `Node.focused` markers widgets render with)
    /// to `n`, or nowhere for null. Nodes that reconciliation pruned between
    /// frames are skipped rather than written through a dangling pointer.
    fn setFocus(self: *App, n: ?*node.Node) void {
        if (self.focus_node) |old| {
            if (old != n and contains(self.root_node, old)) old.focused = false;
        }
        self.focus_node = n;
        if (n) |new| new.focused = true;
    }

    /// Deliver a mouse press / drag / release. The press bubbles up from the
    /// hit node to the first element carrying an `onmouse` handler; that
    /// element captures the whole gesture, so drags keep flowing even after
    /// the cursor left its box.
    fn dispatchMouse(self: *App, ev: element.MouseEvent) void {
        switch (ev.action) {
            .press => {
                self.press_target = null;
                var current = hitTest(self.root_node, ev.x, ev.y);
                while (current) |n| {
                    if (n.onmouse != null) {
                        self.press_target = n;
                        break;
                    }
                    current = n.parent;
                }
                const target = self.press_target orelse return;
                if (target.onmouse) |h| h.func(h.data, &ev);
            },
            .move, .release => {
                const target = self.pressValid() orelse return;
                if (target.onmouse) |h| h.func(h.data, &ev);
            },
        }
    }

    /// The capture target, but only while it is still part of the tree
    /// (reconciliation may have pruned it mid-gesture).
    fn pressValid(self: *App) ?*node.Node {
        const n = self.press_target orelse return null;
        if (contains(self.root_node, n)) return n;
        self.press_target = null;
        return null;
    }

    /// Move the nearest scroll container under the cursor by one wheel notch.
    fn dispatchScroll(self: *App, y: f32) void {
        var current = hitTest(self.root_node, self.cursor_x, self.cursor_y);
        while (current) |n| {
            if (n.scroll) |*st| {
                if (!st.spec.wheel) return; // the page scrolls instead
                // One wheel notch moves the content by about one line-group.
                const step: f32 = 56;
                st.offset = @max(st.offset - y * step, 0);
                return;
            }
            current = n.parent;
        }
    }

    /// A press lands on a scroll container's scrollbar thumb when it sits in
    /// the strip the thumb is painted in (a touch wider than the 5px of ink,
    /// so the thin strip is still grabbable). The thumb geometry mirrors
    /// `paintScrollbar`.
    fn beginScrollDrag(self: *App, x: f32, y: f32) bool {
        var current = hitTest(self.root_node, x, y);
        while (current) |n| {
            if (n.scroll) |st| {
                const max = st.maxOffset();
                if (max > 0) {
                    const b = n.bounds();
                    const thumb_h = @max(b.height() * b.height() / st.content_h, 24);
                    const track_h = b.height() - thumb_h;
                    const thumb_top = b.top + track_h * (st.offset / max);
                    if (x >= b.right - 8 and x <= b.right and
                        y >= thumb_top and y <= thumb_top + thumb_h)
                    {
                        self.scroll_drag = .{ .node = n, .grab_y = y - thumb_top };
                        return true;
                    }
                }
                // The press is inside this container but not on its thumb:
                // a nested container may still own the point, keep walking.
            }
            current = n.parent;
        }
        return false;
    }

    /// Move the dragged thumb so the grabbed point follows the cursor: the
    /// thumb's position maps linearly onto the scroll offset.
    fn moveScrollDrag(self: *App, y: f32) void {
        const drag = &(self.scroll_drag orelse return);
        if (!contains(self.root_node, drag.node)) {
            self.scroll_drag = null;
            return;
        }
        if (drag.node.scroll) |*st| {
            const max = st.maxOffset();
            if (max <= 0) return;
            const b = drag.node.bounds();
            const thumb_h = @max(b.height() * b.height() / st.content_h, 24);
            const track_h = b.height() - thumb_h;
            if (track_h <= 0) return;
            const desired = y - drag.grab_y - b.top;
            st.offset = std.math.clamp(max * desired / track_h, 0, max);
        } else {
            self.scroll_drag = null;
        }
    }

    /// The focus node, but only if it is still part of the tree (reconciliation
    /// may have pruned it between frames).
    fn focusValid(self: *App) ?*node.Node {
        const n = self.focus_node orelse return null;
        if (contains(self.root_node, n)) return n;
        self.focus_node = null;
        return null;
    }

    /// Re-evaluate which node is under the cursor, firing enter / leave
    /// handlers and updating the mouse cursor shape.
    ///
    /// Hover works on ancestor chains rather than the single hit node, so a
    /// container learns about the cursor entering any of its descendants:
    /// a tooltip wrapper around a button, for instance. Common ancestors
    /// stay hovered while the cursor moves between siblings, so handlers
    /// (a tooltip's delay timer) don't flicker.
    fn updateHover(self: *App) void {
        const hit = hitTest(self.root_node, self.cursor_x, self.cursor_y);
        // Reconciliation may have pruned the hovered node since the last
        // frame; its pointer is stale and must not be dereferenced.
        var old_chain: [chain_cap]?*node.Node = undefined;
        for (&old_chain) |*slot| slot.* = null;
        const old: ?*node.Node = if (self.hover_node) |o|
            (if (contains(self.root_node, o)) o else null)
        else
            null;
        if (old == null) self.hover_node = null;
        if (hit == self.hover_node) {
            if (hit) |n| self.applyCursor(n);
            return;
        }
        const old_len = chain(old, &old_chain, self.root_node);

        var new_chain: [chain_cap]?*node.Node = undefined;
        for (&new_chain) |*slot| slot.* = null;
        const new_len = chain(hit, &new_chain, self.root_node);

        // Nodes leaving the chain run leave (deepest first).
        var i: usize = 0;
        while (i < old_len) : (i += 1) {
            const o = old_chain[i].?;
            if (containsChain(&new_chain, new_len, o)) continue;
            if (o.onmouseleave) |h| h.func(h.data);
        }
        // Nodes joining the chain run enter (deepest first).
        i = 0;
        while (i < new_len) : (i += 1) {
            const n = new_chain[i].?;
            if (containsChain(&old_chain, old_len, n)) continue;
            if (n.onmouseenter) |h| h.func(h.data);
        }
        if (hit) |n| self.applyCursor(n);
        self.hover_node = hit;
    }

    fn applyCursor(self: *App, n: *node.Node) void {
        // Nothing up the chain declares a cursor: fall back to the default
        // arrow. Returning without setting anything would keep the previous
        // shape, leaking an I-beam out of a text field into the title bar -
        // and into the window drag started from it.
        var cursor: element.Cursor = .arrow;
        var current: ?*node.Node = n;
        while (current) |c| {
            if (c.cursor) |cur| {
                cursor = cur;
                break;
            }
            current = c.parent;
        }
        self.window.setCursor(switch (cursor) {
            .arrow => .arrow,
            .hand => .hand,
            .ibeam => .ibeam,
        });
    }
};

/// Find the deepest node whose box contains `(x, y)`, preferring later
/// siblings (which paint on top).
fn hitTest(n: *node.Node, x: f32, y: f32) ?*node.Node {
    const b = n.bounds();
    const inside = !(x < b.left or x > b.right or y < b.top or y > b.bottom);
    if (!inside) {
        // Absolutely positioned children (popovers, menus, tooltips, modal
        // layers) are laid out outside their host box and stay interactive
        // there, so a box they hang from is not skipped just because the
        // point is outside it.
        switch (n.kind) {
            .component => {
                if (n.child) |c| {
                    if (hitTest(c, x, y)) |hit| return hit;
                }
            },
            .rect => {
                const kids = n.children.items;
                var i = kids.len;
                while (i > 0) {
                    i -= 1;
                    // Flow content is confined to this box by the layout;
                    // only component subtrees and absolutely positioned
                    // layers can reach beyond it.
                    if (kids[i].kind == .component or kids[i].style.position == .absolute) {
                        if (hitTest(kids[i], x, y)) |hit| return hit;
                    }
                }
            },
            else => {},
        }
        return null;
    }

    switch (n.kind) {
        .component => {
            if (n.child) |c| {
                if (hitTest(c, x, y)) |hit| return hit;
            }
        },
        .rect => {
            const kids = n.children.items;
            var i = kids.len;
            while (i > 0) {
                i -= 1;
                // Scroll containers clip their children: content laid out
                // outside the viewport is painted (and must stay) invisible,
                // so it is not interactive either.
                if (n.scroll != null) {
                    const cb = n.bounds();
                    const kb = kids[i].bounds();
                    if (kb.right < cb.left or kb.left > cb.right or
                        kb.bottom < cb.top or kb.top > cb.bottom) continue;
                }
                if (hitTest(kids[i], x, y)) |hit| return hit;
            }
        },
        .text, .image, .shape => {},
    }
    return n;
}

/// Maximum depth of a hover chain (root ... hit node) tracked in `updateHover`.
const chain_cap = 64;

/// The chain of nodes from `start` up to (and including) `root`, filled
/// deepest first. Returns 0 when `start` is not reachable from `root`
/// (the node left the tree), so stale pointers are detected cheaply.
fn chain(start: ?*node.Node, out: *[chain_cap]?*node.Node, root: *node.Node) usize {
    var len: usize = 0;
    var current = start;
    while (current) |n| : (current = n.parent) {
        if (len >= out.len) return 0; // deeper than the buffer: unusable
        out[len] = n;
        len += 1;
        if (n == root) return len;
    }
    return 0;
}

/// Is `target` a member of `c` (the tail of a chain buffer)?
fn containsChain(c: *[chain_cap]?*node.Node, len: usize, target: *node.Node) bool {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (c[i] == target) return true;
    }
    return false;
}

/// Is `target` still reachable from `root`? Retained nodes are reused across
/// frames but may be pruned when the tree reshapes, so a focus or hover
/// pointer found in an earlier frame can go stale.
fn contains(root: *node.Node, target: *node.Node) bool {
    if (root == target) return true;
    if (root.child) |c| {
        if (contains(c, target)) return true;
    }
    for (root.children.items) |c| {
        if (contains(c, target)) return true;
    }
    return false;
}

/// The first node in tree order asking for the initial keyboard focus.
fn findAutofocus(n: *node.Node) ?*node.Node {
    if (n.autofocus) return n;
    if (n.child) |c| {
        if (findAutofocus(c)) |f| return f;
    }
    for (n.children.items) |c| {
        if (findAutofocus(c)) |f| return f;
    }
    return null;
}
