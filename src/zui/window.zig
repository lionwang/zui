//! A GLFW window with an OpenGL context, plus input event collection.
const std = @import("std");
const events = @import("events.zig");

const glfw = @cImport({
    @cInclude("GLFW/glfw3.h");
});

pub const CursorShape = enum { arrow, hand, ibeam };
pub const Window = struct {
    handle: *glfw.GLFWwindow,
    width: u32,
    height: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    scale: f32,
    queue: *events.EventQueue,
    title: []const u8,
    /// Notified by GLFW when the window must repaint outside the frame loop
    /// (Win32 repaints during the modal resizing loop).
    refresh_fn: ?*const fn (*anyopaque) void = null,
    refresh_user: ?*anyopaque = null,
    cursors: [3]?*glfw.GLFWcursor = .{ null, null, null },

    pub const Config = struct {
        title: []const u8 = "zui app",
        width: u32 = 800,
        height: u32 = 600,
        /// Force a specific window scale (content scale). 0 = detect from monitor.
        scale: f32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Window {
        const queue = try allocator.create(events.EventQueue);
        queue.* = events.EventQueue.init(allocator);

        if (glfw.glfwInit() == 0) return error.GlfwInitFailed;
        errdefer glfw.glfwTerminate();

        glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_OPENGL_API);
        glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 3);
        glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 3);
        glfw.glfwWindowHint(glfw.GLFW_SCALE_TO_MONITOR, 1);
        glfw.glfwWindowHint(glfw.GLFW_VISIBLE, 1);

        const title_z = try allocator.allocSentinel(u8, config.title.len, 0);
        @memcpy(title_z[0..config.title.len], config.title);

        const handle = glfw.glfwCreateWindow(
            @intCast(config.width),
            @intCast(config.height),
            title_z.ptr,
            null,
            null,
        ) orelse return error.WindowCreationFailed;

        const self = try allocator.create(Window);
        self.* = Window{
            .handle = handle,
            .width = config.width,
            .height = config.height,
            .framebuffer_width = 0,
            .framebuffer_height = 0,
            .scale = if (config.scale > 0) config.scale else 1.0,
            .queue = queue,
            .title = config.title,
        };

        glfw.glfwSetWindowUserPointer(handle, @ptrCast(self));
        glfw.glfwMakeContextCurrent(handle);

        // Synchronize window / framebuffer sizes and scale.
        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        glfw.glfwGetFramebufferSize(handle, &fb_w, &fb_h);
        self.framebuffer_width = @intCast(fb_w);
        self.framebuffer_height = @intCast(fb_h);

        var win_w: c_int = 0;
        var win_h: c_int = 0;
        glfw.glfwGetWindowSize(handle, &win_w, &win_h);
        self.width = @intCast(win_w);
        self.height = @intCast(win_h);

        if (config.scale <= 0) {
            var sx: f32 = 1.0;
            var sy: f32 = 1.0;
            glfw.glfwGetWindowContentScale(handle, &sx, &sy);
            self.scale = @max(sx, sy);
            if (self.scale <= 0) self.scale = 1.0;
        }

        _ = glfw.glfwSetFramebufferSizeCallback(handle, framebufferSizeCallback);
        _ = glfw.glfwSetWindowSizeCallback(handle, windowSizeCallback);
        _ = glfw.glfwSetCursorPosCallback(handle, cursorPosCallback);
        _ = glfw.glfwSetMouseButtonCallback(handle, mouseButtonCallback);
        _ = glfw.glfwSetScrollCallback(handle, scrollCallback);
        _ = glfw.glfwSetKeyCallback(handle, keyCallback);
        _ = glfw.glfwSetCharModsCallback(handle, charModsCallback);
        _ = glfw.glfwSetWindowFocusCallback(handle, windowFocusCallback);
        _ = glfw.glfwSetWindowRefreshCallback(handle, refreshCallback);

        return self;
    }

    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        for (self.cursors) |maybe| {
            if (maybe) |cur| glfw.glfwDestroyCursor(cur);
        }
        self.queue.deinit();
        allocator.destroy(self.queue);
        glfw.glfwDestroyWindow(self.handle);
        glfw.glfwTerminate();
    }

    /// Set the mouse cursor shape, caching the platform cursors.
    pub fn setCursor(self: *Window, shape: CursorShape) void {
        const idx: usize = @intFromEnum(shape);
        if (self.cursors[idx] == null) {
            self.cursors[idx] = glfw.glfwCreateStandardCursor(switch (shape) {
                .arrow => glfw.GLFW_ARROW_CURSOR,
                .hand => glfw.GLFW_HAND_CURSOR,
                .ibeam => glfw.GLFW_IBEAM_CURSOR,
            });
        }
        glfw.glfwSetCursor(self.handle, self.cursors[idx]);
    }

    pub fn shouldClose(self: Window) bool {
        return glfw.glfwWindowShouldClose(self.handle) != 0;
    }

    pub fn swapBuffers(self: Window) void {
        glfw.glfwSwapBuffers(self.handle);
    }

    pub fn pollEvents(self: *Window) []events.Event {
        glfw.glfwPollEvents();
        return self.queue.drain();
    }

    /// Programmatically resize the window (screen coordinates).
    pub fn setSize(self: *Window, width: u32, height: u32) void {
        glfw.glfwSetWindowSize(self.handle, @intCast(width), @intCast(height));
    }

    pub fn requestClose(self: Window) void {
        glfw.glfwSetWindowShouldClose(self.handle, 1);
    }

    /// Install a repaint hook. GLFW calls it through glfwSetWindowRefreshCallback,
    /// which on Windows fires from inside the modal move/size loop, where
    /// glfwPollEvents does not return until the user finishes dragging.
    pub fn setRefreshCallback(self: *Window, user: *anyopaque, callback: *const fn (*anyopaque) void) void {
        self.refresh_user = user;
        self.refresh_fn = callback;
    }

    // ------------------------------------------------------------------
    // GLFW callbacks
    // ------------------------------------------------------------------

    fn fromHandle(handle: ?*glfw.GLFWwindow) *Window {
        return @ptrCast(@alignCast(glfw.glfwGetWindowUserPointer(handle).?));
    }

    fn framebufferSizeCallback(handle: ?*glfw.GLFWwindow, w: c_int, h: c_int) callconv(.c) void {
        const self = fromHandle(handle);
        self.framebuffer_width = @intCast(w);
        self.framebuffer_height = @intCast(h);
        self.queue.push(.{ .resize = .{ .width = @intCast(w), .height = @intCast(h) } });
    }

    fn windowSizeCallback(handle: ?*glfw.GLFWwindow, w: c_int, h: c_int) callconv(.c) void {
        const self = fromHandle(handle);
        self.width = @intCast(w);
        self.height = @intCast(h);
    }

    fn cursorPosCallback(handle: ?*glfw.GLFWwindow, x: f64, y: f64) callconv(.c) void {
        const self = fromHandle(handle);
        self.queue.push(.{ .cursor_move = .{
            .x = @as(f32, @floatCast(x)),
            .y = @as(f32, @floatCast(y)),
        } });
    }

    fn mouseButtonCallback(handle: ?*glfw.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
        const self = fromHandle(handle);
        var x: f64 = 0;
        var y: f64 = 0;
        glfw.glfwGetCursorPos(handle, &x, &y);
        self.queue.push(.{ .mouse_button = .{
            .button = switch (button) {
                glfw.GLFW_MOUSE_BUTTON_LEFT => .left,
                glfw.GLFW_MOUSE_BUTTON_RIGHT => .right,
                glfw.GLFW_MOUSE_BUTTON_MIDDLE => .middle,
                else => .other,
            },
            .action = switch (action) {
                glfw.GLFW_PRESS => .press,
                glfw.GLFW_REPEAT => .repeat,
                else => .release,
            },
            .mods = modsFromGlfw(mods),
            .x = @as(f32, @floatCast(x)),
            .y = @as(f32, @floatCast(y)),
        } });
    }

    fn scrollCallback(handle: ?*glfw.GLFWwindow, x: f64, y: f64) callconv(.c) void {
        const self = fromHandle(handle);
                self.queue.push(.{ .scroll = .{
            .x = @as(f32, @floatCast(x)),
            .y = @as(f32, @floatCast(y)),
        } });
    }

    fn keyCallback(handle: ?*glfw.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
        const self = fromHandle(handle);
        self.queue.push(.{ .key = .{
            .key = @enumFromInt(@as(u32, @intCast(key))),
            .scancode = scancode,
            .action = switch (action) {
                glfw.GLFW_PRESS => .press,
                glfw.GLFW_REPEAT => .repeat,
                else => .release,
            },
            .mods = modsFromGlfw(mods),
        } });
    }

    fn charModsCallback(handle: ?*glfw.GLFWwindow, codepoint: c_uint, mods: c_int) callconv(.c) void {
        const self = fromHandle(handle);
        self.queue.push(.{ .char = .{
            .codepoint = codepoint,
            .mods = modsFromGlfw(mods),
        } });
    }

    fn windowFocusCallback(handle: ?*glfw.GLFWwindow, focused: c_int) callconv(.c) void {
        const self = fromHandle(handle);
        self.queue.push(.{ .focus = .{ .focused = focused != 0 } });
    }

    fn refreshCallback(handle: ?*glfw.GLFWwindow) callconv(.c) void {
        const self = fromHandle(handle);
        if (self.refresh_fn) |f| f(self.refresh_user.?);
    }

    /// Layout space is measured in logical pixels; the framebuffer is in
    /// physical pixels. Events are reported in logical pixels.
    pub fn contentScale(self: Window) f32 {
        const fw: f32 = @floatFromInt(self.framebuffer_width);
        const w: f32 = @floatFromInt(self.width);
        if (w > 0 and fw > 0) return fw / w;
        return 1.0;
    }
};

fn modsFromGlfw(mods: c_int) events.Modifier {
    return .{
        .shift = (mods & glfw.GLFW_MOD_SHIFT) != 0,
        .control = (mods & glfw.GLFW_MOD_CONTROL) != 0,
        .alt = (mods & glfw.GLFW_MOD_ALT) != 0,
        .super = (mods & glfw.GLFW_MOD_SUPER) != 0,
        .caps_lock = (mods & glfw.GLFW_MOD_CAPS_LOCK) != 0,
        .num_lock = (mods & glfw.GLFW_MOD_NUM_LOCK) != 0,
    };
}
