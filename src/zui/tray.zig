//! System tray (notification area) icons, Windows only.
//!
//! A `Tray` is a hidden, message-only window paired with a NOTIFYICON: the
//! icon appears in the notification area, clicks arrive as window messages
//! on that hidden window, and GLFW's own message pump dispatches them (its
//! PeekMessage loop covers the whole thread queue, not just GLFW windows).
//! So callbacks run from the message thread, inside the app's normal event
//! poll - exactly like GLFW's mouse and key callbacks. Keep them short.
//!
//! ```zig
//! var tray = try zui.Tray.init(allocator, .{
//!     .icon_path = "assets/app.ico",
//!     .tooltip = "MyApp",
//!     .owner = app.window,
//!     .on_click = restore,
//!     .click_data = @ptrCast(app),
//!     .menu = &.{
//!         .{ .label = "Open", .handler = restore, .data = @ptrCast(app) },
//!         .{ .separator = true },
//!         .{ .label = "Quit", .handler = quit, .data = @ptrCast(app) },
//!     },
//! });
//! defer tray.deinit();
//! ```

const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");
const window_mod = @import("window.zig");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zui::tray");

var class_registered: bool = false;
/// Each tray gets its own callback message in the WM_APP range, so several
/// trays can share the (registered once) message-only window class.
var next_id: u32 = 0;

/// One entry of a tray's right-click menu.
pub const MenuItem = struct {
    label: []const u8 = "",
    /// Separator entries are dividers; `label` and `handler` are ignored.
    separator: bool = false,
    enabled: bool = true,
    /// Opaque payload passed back to `handler`.
    data: ?*anyopaque = null,
    /// Invoked from the message thread, during the app event poll, when the
    /// user picks this entry.
    handler: ?*const fn (data: ?*anyopaque) void = null,
};

pub const Config = struct {
    /// UTF-8 path to an .ico file (embed a 16 and a 32 px size; the
    /// notification area uses the small one).
    icon_path: ?[]const u8 = null,
    tooltip: []const u8 = "",
    /// The app window the icon belongs to: it owns the popup menu and the
    /// focus dance around showing it. Optional, but right-click menus
    /// behave better with it.
    owner: ?*window_mod.Window = null,
    /// Left click on the tray icon. Windows only.
    on_click: ?*const fn (data: ?*anyopaque) void = null,
    click_data: ?*anyopaque = null,
    /// Right-click context menu. Empty means right clicks do nothing.
    /// The tray keeps a reference to the slice: keep it alive for the
    /// tray's lifetime.
    menu: []const MenuItem = &.{},
};

pub const Tray = struct {
    allocator: std.mem.Allocator,
    /// The hidden message-only window that receives the icon's callbacks.
    hwnd: win32.HWND,
    notify: win32.NOTIFYICONDATAW,
    /// Owned (loaded from `icon_path`); destroyed in deinit.
    icon: win32.Icon = .{},
    config: Config,
    /// This tray's callback message (WM_APP + id); identifies our messages
    /// inside the shared window procedure.
    callback_msg: u32,

    /// Add an icon to the notification area. `error.UnsupportedPlatform`
    /// anywhere but Windows; `error.IconLoadFailed` / `error.TrayAddFailed`
    /// when the icon cannot be read or the shell rejects the icon.
    pub fn init(allocator: std.mem.Allocator, config: Config) !*Tray {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

        const module = try registerTrayClass();

        const tray = try allocator.create(Tray);
        errdefer allocator.destroy(tray);

        const id = next_id;
        next_id += 1;
        const callback_msg = win32.WM_APP + id;

        const hwnd = win32.CreateWindowExW(
            0,
            class_name,
            class_name,
            0,
            0,
            0,
            0,
            0,
            win32.HWND_MESSAGE,
            null,
            module,
            null,
        ) orelse return error.TrayWindowFailed;
        errdefer _ = win32.DestroyWindow(hwnd);

        var notify = std.mem.zeroes(win32.NOTIFYICONDATAW);
        notify.cbSize = @sizeOf(win32.NOTIFYICONDATAW);
        notify.hWnd = hwnd;
        notify.uID = id;
        notify.uFlags = win32.NIF_MESSAGE | win32.NIF_ICON | win32.NIF_TIP;
        notify.uCallbackMessage = callback_msg;

        if (config.icon_path) |path| {
            tray.icon = try win32.Icon.loadFile(allocator, path);
        }
        notify.hIcon = tray.icon.small orelse tray.icon.big;
        try setTip(allocator, &notify, config.tooltip);

        if (win32.Shell_NotifyIconW(win32.NIM_ADD, &notify) == 0) {
            tray.icon.destroy();
            return error.TrayAddFailed;
        }

        // The callback lookup key: messages for this window address us.
        // Stored at window-extra index 0 rather than GWLP_USERDATA: the
        // latter needs the class to reserve extra memory, and ours reserves
        // exactly one pointer for this.
        _ = win32.SetWindowLongPtrW(hwnd, 0, @bitCast(@as(usize, @intFromPtr(tray))));

        tray.* = .{
            .allocator = allocator,
            .hwnd = hwnd,
            .notify = notify,
            .config = config,
            .callback_msg = callback_msg,
        };
        return tray;
    }

    pub fn deinit(self: *Tray) void {
        // Unregister the icon first, so it does not linger in the
        // notification area while the callback window goes away.
        _ = win32.Shell_NotifyIconW(win32.NIM_DELETE, &self.notify);
        _ = win32.DestroyWindow(self.hwnd);
        self.icon.destroy();
        self.allocator.destroy(self);
    }

    /// Change the tooltip at runtime.
    pub fn setTooltip(self: *Tray, tooltip: []const u8) !void {
        try setTip(self.allocator, &self.notify, tooltip);
        if (win32.Shell_NotifyIconW(win32.NIM_MODIFY, &self.notify) == 0) return error.TrayModifyFailed;
    }

    /// Show the right-click menu at the cursor (Windows only, message
    /// thread). TrackPopupMenu runs a modal loop, so this blocks the frame
    /// loop until the user picks an entry or clicks away - that is how
    /// native context menus behave.
    fn showMenu(self: *Tray) void {
        if (self.config.menu.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const menu = win32.CreatePopupMenu() orelse return;
        defer _ = win32.DestroyMenu(menu);

        // AppendMenuW ids are 1-based and sequential per appended (i.e.
        // non-separator) entry; remember which config item each id maps to.
        var ids: std.ArrayList(usize) = .empty;
        var next: usize = 1;
        for (self.config.menu, 0..) |item, index| {
            if (item.separator) {
                _ = win32.AppendMenuW(menu, win32.MF_SEPARATOR, 0, null);
                continue;
            }
            const label_w = std.unicode.utf8ToUtf16LeAllocZ(a, item.label) catch return;
            const flags = win32.MF_STRING | (if (item.enabled) 0 else win32.MF_GRAYED);
            if (win32.AppendMenuW(menu, flags, next, label_w.ptr) == 0) return;
            ids.append(a, index) catch return;
            next += 1;
        }

        var pt: win32.POINT = .{};
        if (win32.GetCursorPos(&pt) == 0) return;

        // The focus dance around TrackPopupMenu is the documented recipe
        // for a popup that also closes on an outside click.
        const owner: win32.HWND = if (self.config.owner) |w| (w.nativeHandle() orelse self.hwnd) else self.hwnd;
        const popup_owner = owner orelse return;
        _ = win32.SetForegroundWindow(popup_owner);
        const chosen = win32.TrackPopupMenu(
            menu,
            win32.TPM_LEFTALIGN | win32.TPM_TOPALIGN | win32.TPM_RETURNCMD,
            pt.x,
            pt.y,
            0,
            popup_owner,
            null,
        );
        _ = win32.PostMessageW(popup_owner, win32.WM_NULL, 0, 0);

        // With TPM_RETURNCMD, TrackPopupMenu returns the chosen item id
        // (1-based) or 0 when the menu was cancelled.
        if (chosen > 0) {
            const chosen_id: usize = @intCast(chosen);
            if (chosen_id <= ids.items.len) {
                const item = self.config.menu[ids.items[chosen_id - 1]];
                if (item.handler) |h| h(item.data);
            }
        }
    }

    /// The window procedure of the message-only window class: every tray's
    /// callback lands here, looked up through the pointer stored in the
    /// window's extra memory (index 0).
    fn wndProc(
        hwnd: win32.HWND,
        msg: u32,
        wParam: usize,
        lParam: isize,
    ) callconv(.c) isize {
        const tray_ptr = win32.GetWindowLongPtrW(hwnd, 0);
        if (tray_ptr != 0) {
            const self: *Tray = @ptrFromInt(@as(usize, @bitCast(tray_ptr)));
            if (msg == self.callback_msg) {
                // Classic (pre-Vista) callback contract: the low word of
                // lParam is the mouse message.
                const mouse: u32 = @truncate(@as(usize, @bitCast(lParam)));
                switch (mouse) {
                    win32.WM_LBUTTONUP, win32.WM_LBUTTONDBLCLK => {
                        if (self.config.on_click) |h| h(self.config.click_data);
                    },
                    win32.WM_RBUTTONUP, win32.WM_RBUTTONDBLCLK => self.showMenu(),
                    else => {},
                }
                return 0;
            }
        }
        return win32.DefWindowProcW(hwnd, msg, wParam, lParam);
    }
};

/// Write `tooltip` into the NOTIFYICONDATAW's szTip (NIF_TIP set, the array
/// is NUL-terminated and truncated to 127 wchars).
fn setTip(
    allocator: std.mem.Allocator,
    notify: *win32.NOTIFYICONDATAW,
    tooltip: []const u8,
) !void {
    const wtip = try std.unicode.utf8ToUtf16LeAlloc(allocator, tooltip);
    defer allocator.free(wtip);
    const max = notify.szTip.len - 1;
    const n = @min(wtip.len, max);
    @memcpy(notify.szTip[0..n], wtip[0..n]);
    @memset(notify.szTip[n..], 0);
    notify.uFlags |= win32.NIF_TIP;
}

/// Register the message-only window class once per process and return the
/// module handle the class (and its windows) belong to.
fn registerTrayClass() !win32.HMODULE {
    const module = win32.GetModuleHandleW(null) orelse return error.TrayClassFailed;
    if (class_registered) return module;

    var wc = std.mem.zeroes(win32.WNDCLASSEXW);
    wc.cbSize = @sizeOf(win32.WNDCLASSEXW);
    wc.lpfnWndProc = Tray.wndProc;
    // One pointer of per-window storage: the Tray* the WndProc looks up.
    wc.cbWndExtra = @sizeOf(usize);
    wc.hInstance = module;
    wc.lpszClassName = class_name;
    if (win32.RegisterClassExW(&wc) == 0) return error.TrayClassFailed;
    class_registered = true;
    return module;
}
