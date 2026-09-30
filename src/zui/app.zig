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

const glfw = @cImport({
    @cInclude("GLFW/glfw3.h");
});

/// Configuration for `App.init`.
pub const AppConfig = struct {
    title: []const u8 = "zui app",
    width: u32 = 800,
    height: u32 = 600,
    background: u32 = 0xFF1E1E2E,
    /// Close the window when Escape is pressed.
    exit_on_escape: bool = true,
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
    frame_count: u32 = 0,

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
                },
                .cursor_move => |c| {
                    self.cursor_x = c.x;
                    self.cursor_y = c.y;
                },
                .mouse_button => |mb| {
                    if (mb.button == .left and mb.action == .press) {
                        self.dispatchClick(mb.x, mb.y);
                    }
                },
                else => {},
            }
        }
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

        const root_el: element.Element = .{ .rect = .{
            .style = .{ .width = fw, .height = fh },
            .children = &.{.{ .component = .{
                .name = "root",
                .render = self.root_render,
                .props = self.root_props,
            } }},
        } };
        _ = try reconcile.reconcile(self.allocator, arena, self.root_node, root_el);

        // ---- layout ---------------------------------------------------
        try layout.layout(self.root_node, .{
            .font_collection = self.font_collection,
            .arena = arena,
        }, fw, fh);

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

    /// Read the whole framebuffer back and hand it to cb.
    fn captureFrame(self: *App, cb: *const fn ([]const u8, i32, i32) void) void {
        const w: i32 = @intCast(self.window.framebuffer_width);
        h: {
            const h: i32 = @intCast(self.window.framebuffer_height);
            if (w == 0 or h == 0) break :h;
            const buf = self.allocator.alloc(u8, @as(usize, @intCast(w * h)) * 4) catch return;
            defer self.allocator.free(buf);
            if (!self.surface.readPixels(buf, w, h)) return;
            cb(buf, w, h);
        }
    }

    /// Deliver a click to the deepest node under the cursor, bubbling up to
    /// every ancestor that also has a click handler.
    fn dispatchClick(self: *App, x: f32, y: f32) void {
        var current = hitTest(self.root_node, x, y);
        while (current) |n| {
            if (n.onclick) |h| h.func(h.data);
            current = n.parent;
        }
    }

    /// Re-evaluate which node is under the cursor, firing enter / leave
    /// handlers and updating the mouse cursor shape.
    fn updateHover(self: *App) void {
        const hit = hitTest(self.root_node, self.cursor_x, self.cursor_y);
        if (hit == self.hover_node) {
            if (hit) |n| self.applyCursor(n);
            return;
        }
        if (self.hover_node) |old| {
            if (old.onmouseleave) |h| h.func(h.data);
        }
        if (hit) |new| {
            if (new.onmouseenter) |h| h.func(h.data);
            self.applyCursor(new);
        }
        self.hover_node = hit;
    }

    fn applyCursor(self: *App, n: *node.Node) void {
        var cursor: element.Cursor = .arrow;
        var current: ?*node.Node = n;
        var found = false;
        while (current) |c| {
            if (c.cursor) |cur| {
                cursor = cur;
                found = true;
                break;
            }
            current = c.parent;
        }
        if (!found) return;
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
    if (x < b.left or x > b.right or y < b.top or y > b.bottom) return null;

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
                if (hitTest(kids[i], x, y)) |hit| return hit;
            }
        },
        .text, .image => {},
    }
    return n;
}