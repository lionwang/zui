//! A GLFW window with an OpenGL context, plus input event collection.
const std = @import("std");
const builtin = @import("builtin");
const events = @import("events.zig");

const glfw = @import("glfw");

const win32 = @import("win32.zig");

/// GLFW's native accessor; compiled into the win32 backend sources.
extern fn glfwGetWin32Window(handle: ?*glfw.GLFWwindow) callconv(.c) win32.HWND;

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
    /// The shape `setCursor` last applied (what the hover pass requested).
    cursor_shape: CursorShape = .arrow,
    /// Live cursor position in logical pixels, updated by the cursor-move
    /// callback. Widgets read it while rendering (chart tooltips follow the
    /// mouse without capturing a press).
    cursor_x: f32 = 0,
    cursor_y: f32 = 0,
    /// The icon loaded from `Config.icon` (owned: destroyed in deinit).
    /// Null when the window was given no icon path.
    icon: ?win32.Icon = null,

    pub const Config = struct {
        title: []const u8 = "zui app",
        width: u32 = 800,
        height: u32 = 600,
        /// Force a specific window scale (content scale). 0 = detect from monitor.
        scale: f32 = 0,
        /// Keep the native window chrome: the title bar with the system menu
        /// (title-bar icon, Alt+Space popup) and its minimize / maximize /
        /// close buttons. Setting this false makes the window frameless -
        /// no caption, no system menu, no OS buttons, and Alt+F4 is gone
        /// with the menu - so the app must draw its own title bar; `App`
        /// renders one automatically (see `AppConfig.system_menu`).
        /// Windows only; ignored on other platforms.
        system_menu: bool = true,
        /// UTF-8 path to an .ico file (embed a 16 and a 32 px size in it) to
        /// use as the app icon: the title-bar icon, Alt+Tab and the taskbar
        /// (Windows' equivalent of a dock icon) all take it. Loaded with
        /// LoadImageW, so .ico only - PNG / other formats fail with
        /// `error.IconLoadFailed`. Windows only.
        icon: ?[]const u8 = null,
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
        glfw.glfwWindowHint(glfw.GLFW_DECORATED, if (config.system_menu) 1 else 0);

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

        if (!config.system_menu) framelessWindow(handle);

        if (config.icon) |path| {
            // A missing icon is not fatal: the window just keeps the default
            // (GLFW) icon rather than taking the app down.
            self.icon = win32.Icon.loadFile(allocator, path) catch |err| blk: {
                std.debug.print(
                    "zui: could not load the window icon from {s} ({s}); using the default\n",
                    .{ path, @errorName(err) },
                );
                break :blk null;
            };
            if (self.icon) |icon| self.setIcon(icon);
        }

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
        if (self.icon) |*icon| icon.destroy();
        self.queue.deinit();
        allocator.destroy(self.queue);
        glfw.glfwDestroyWindow(self.handle);
        glfw.glfwTerminate();
    }

    /// Set the mouse cursor shape, caching the platform cursors. The last
    /// shape is remembered in `cursor_shape` (tests assert on it).
    pub fn setCursor(self: *Window, shape: CursorShape) void {
        const idx: usize = @backingInt(shape);
        if (self.cursors[idx] == null) {
            self.cursors[idx] = glfw.glfwCreateStandardCursor(switch (shape) {
                .arrow => glfw.GLFW_ARROW_CURSOR,
                .hand => glfw.GLFW_HAND_CURSOR,
                .ibeam => glfw.GLFW_IBEAM_CURSOR,
            });
        }
        self.cursor_shape = shape;
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

    /// Minimize to the taskbar.
    pub fn minimize(self: Window) void {
        glfw.glfwIconifyWindow(self.handle);
    }

    /// Maximize over the work area of the monitor.
    pub fn maximize(self: Window) void {
        glfw.glfwMaximizeWindow(self.handle);
    }

    /// Undo a minimize or maximize.
    pub fn restore(self: Window) void {
        glfw.glfwRestoreWindow(self.handle);
    }

    /// Maximized right now (what the toggle button should show).
    pub fn maximized(self: Window) bool {
        return glfw.glfwGetWindowAttrib(self.handle, glfw.GLFW_MAXIMIZED) != 0;
    }

    pub fn toggleMaximize(self: Window) void {
        if (self.maximized()) self.restore() else self.maximize();
    }

    /// Start the native modal drag, as if the press had landed on a real
    /// caption: `PostMessage` runs DefWindowProc's move loop, which handles
    /// edge snapping and cancels itself on release. Call from the custom
    /// title bar's press handler. Windows only.
    pub fn startDrag(self: Window) void {
        if (builtin.os.tag != .windows) return;
        const hwnd = glfwGetWin32Window(self.handle) orelse return;
        _ = win32.ReleaseCapture();
        _ = win32.PostMessageW(hwnd, win32.WM_NCLBUTTONDOWN, win32.HTCAPTION, win32.GetMessagePos());
    }

    /// Set the app icon (title bar, Alt+Tab and the taskbar - the Windows
    /// stand-in for a dock icon). The window takes no ownership: `icon` (and
    /// the handles it loaded) stays the caller's, so replace it and destroy
    /// the old one when changing the icon at runtime.
    pub fn setIcon(self: *Window, icon: win32.Icon) void {
        if (builtin.os.tag != .windows) return;
        const hwnd = glfwGetWin32Window(self.handle) orelse return;
        if (icon.big) |h| _ = win32.SendMessageW(hwnd, win32.WM_SETICON, win32.ICON_BIG, @bitCast(@as(usize, @intFromPtr(h))));
        if (icon.small) |h| _ = win32.SendMessageW(hwnd, win32.WM_SETICON, win32.ICON_SMALL, @bitCast(@as(usize, @intFromPtr(h))));
    }

    /// The backing native window handle (HWND); null on non-Windows
    /// platforms and when the GLFW win32 backend is unavailable.
    pub fn nativeHandle(self: Window) win32.HWND {
        if (builtin.os.tag != .windows) return null;
        return glfwGetWin32Window(self.handle);
    }

    /// Hide the window entirely (not in the taskbar either) - e.g. when
    /// minimizing to a tray icon.
    pub fn hide(self: Window) void {
        if (builtin.os.tag != .windows) return;
        const hwnd = glfwGetWin32Window(self.handle) orelse return;
        _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
    }

    /// Undo `hide`.
    pub fn show(self: Window) void {
        if (builtin.os.tag != .windows) return;
        const hwnd = glfwGetWin32Window(self.handle) orelse return;
        _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    }

    /// Bring the window to the foreground - the restore side of the
    /// minimize-to-tray pattern (calls `restore` first if it was
    /// minimized). Windows only.
    pub fn focus(self: *Window) void {
        if (builtin.os.tag != .windows) return;
        const hwnd = glfwGetWin32Window(self.handle) orelse return;
        self.restore();
        _ = win32.SetForegroundWindow(hwnd);
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
        // Tracked live so widgets (chart tooltips) can read the cursor
        // position during a render, not only through event dispatch.
        self.cursor_x = @as(f32, @floatCast(x));
        self.cursor_y = @as(f32, @floatCast(y));
        self.queue.push(.{ .cursor_move = .{
            .x = self.cursor_x,
            .y = self.cursor_y,
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
        // GLFW maps unmapped virtual keys to -1 (GLFW_KEY_UNKNOWN): the key
        // enum is non-exhaustive, but the cast itself must not panic on
        // negative values.
        const key_enum: events.Key = if (key < 0)
            .unknown
        else
            @fromBackingInt(@intCast(@as(u32, @intCast(key))));
        self.queue.push(.{ .key = .{
            .key = key_enum,
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

/// The window procedure the subclass installed by `framelessWindow`
/// replaced, plus the window it belongs to. One slot is enough: a zui app
/// owns a single window, and a second frameless one keeps the stock proc
/// (accepting the stock frame) rather than borrowing the first window's.
var frameless_orig_hwnd: ?win32.HWND = null;
var frameless_orig_proc: ?win32.WndProc = null;

/// `WM_NCCALCSIZE`/`WM_NCHITTEST` handler that makes a `WS_THICKFRAME`
/// frameless window draw no frame *at all*. See `framelessWindow`.
fn framelessProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.c) isize {
    const orig = frameless_orig_proc orelse
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);

    if (msg == win32.WM_NCCALCSIZE) {
        // With `wParam` TRUE, `lParam` is NCCALCSIZE_PARAMS whose `rgrc[0]`
        // holds the proposed window rect; returning 0 while leaving it
        // untouched declares the *whole* window rect client area. (FALSE is
        // the same idea over a plain RECT.) No non-client rect left means
        // nothing for DWM to paint the light-theme white of.
        return 0;
    }

    if (msg == win32.WM_NCHITTEST) {
        // With no frame region left, the default answer is HTCLIENT
        // everywhere; hand back a thin invisible edge zone so the borders
        // still resize and sized cursors show. Anything the app already
        // claims (caption drag, its own buttons) keeps priority.
        const hit = win32.CallWindowProcW(orig, hwnd, msg, wparam, lparam);
        if (@as(usize, @bitCast(hit)) != win32.HTCLIENT) return hit;
        if (win32.IsZoomed(hwnd) != 0) return hit; // no sizing while maximized
        var r: win32.RECT = .{};
        if (win32.GetWindowRect(hwnd, &r) == 0) return hit;
        // GET_X/Y_LPARAM: screen points can be negative on other monitors.
        const lu: u64 = @bitCast(lparam);
        const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(lu)))));
        const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(lu >> 16)))));
        const e: i32 = 4;
        const on_left = x < r.left + e;
        const on_right = x >= r.right - e;
        const on_top = y < r.top + e;
        const on_bottom = y >= r.bottom - e;
        if (on_top and on_left) return @bitCast(win32.HTTOPLEFT);
        if (on_top and on_right) return @bitCast(win32.HTTOPRIGHT);
        if (on_bottom and on_left) return @bitCast(win32.HTBOTTOMLEFT);
        if (on_bottom and on_right) return @bitCast(win32.HTBOTTOMRIGHT);
        if (on_left) return @bitCast(win32.HTLEFT);
        if (on_right) return @bitCast(win32.HTRIGHT);
        if (on_top) return @bitCast(win32.HTTOP);
        if (on_bottom) return @bitCast(win32.HTBOTTOM);
        return hit;
    }

    return win32.CallWindowProcW(orig, hwnd, msg, wparam, lparam);
}

/// Turn an undecorated (`GLFW_DECORATED = 0`) window into a frameless but
/// still resizable one: drop `WS_SYSMENU` (the system menu, the Alt+Space
/// popup and, with no caption to draw them in, the OS buttons) and add
/// `WS_THICKFRAME` so the edges keep their sizing hit area, plus
/// `WS_MAXIMIZEBOX` so `ShowWindow(SW_MAXIMIZE)` (what a maximize request
/// uses on a visible window) does not get silently ignored.
/// `WS_THICKFRAME` would also carve a ~7px non-client border out of the
/// client area for its sizing hit area, and DWM paints that border white in
/// a light theme - a bright band around the app. The window is therefore
/// also subclassed: `WM_NCCALCSIZE` pulls the client area back over the
/// whole window rect and `WM_NCHITTEST` re-adds a 4px sizing zone, so the
/// resize behavior survives while the app's pixels reach the window edge.
/// `SetWindowPos` with `SWP_FRAMECHANGED` makes Win32 rebuild the non-client
/// area for the new style (through the subclass); without it the old layout
/// sticks until something else forces a frame change.
fn framelessWindow(handle: *glfw.GLFWwindow) void {
    if (builtin.os.tag != .windows) return;

    const hwnd = glfwGetWin32Window(handle) orelse return;
    const style = win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE);
    var new_style = style & ~@as(isize, @intCast(win32.WS_SYSMENU));
    new_style |= @as(isize, @intCast(win32.WS_THICKFRAME | win32.WS_MAXIMIZEBOX));
    _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_STYLE, new_style);
    if (frameless_orig_hwnd == null) {
        const prev = win32.SetWindowLongPtrW(
            hwnd,
            win32.GWLP_WNDPROC,
            @bitCast(@intFromPtr(&framelessProc)),
        );
        // 0 means the swap failed: the window then keeps the stock proc and
        // the visible frame, which is a cosmetic step back, not a broken one.
        if (prev != 0) {
            frameless_orig_hwnd = hwnd;
            frameless_orig_proc = @as(win32.WndProc, @ptrFromInt(@as(usize, @bitCast(prev))));
        }
    }
    _ = win32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED,
    );
}

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
