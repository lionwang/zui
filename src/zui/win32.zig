//! Minimal Win32 ABI bindings shared by the window and tray modules.
//!
//! Declared by hand rather than translating <windows.h> with clang (which GLFW's
//! `glfw3native.h` would drag in): only a handful of stable ABI symbols are
//! needed - handles, window styles, icon loading and the notification-area
//! structs - and translate-c of the full Windows headers is slow and noisy.
//! Windows only: every caller guards on `builtin.os.tag`.

const std = @import("std");

pub const HWND = ?*anyopaque;
pub const HICON = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const HMODULE = ?*anyopaque;
pub const HANDLE = ?*anyopaque;

/// A Win32 GUID (`guidItem` in NOTIFYICONDATAW); kept zeroed.
pub const GUID = extern struct {
    Data1: u32 = 0,
    Data2: u16 = 0,
    Data3: u16 = 0,
    Data4: [8]u8 = .{0} * *8,
};

pub const POINT = extern struct { x: c_long = 0, y: c_long = 0 };

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = 0,
    style: u32 = 0,
    lpfnWndProc: ?*const fn (HWND, u32, usize, isize) callconv(.c) isize = null,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: HMODULE = null,
    hIcon: HICON = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: ?[*:0]const u16 = null,
    hIconSm: HICON = null,
};

pub const NOTIFYICONDATAW = extern struct {
    cbSize: u32 = 0,
    hWnd: HWND = null,
    uID: u32 = 0,
    uFlags: u32 = 0,
    uCallbackMessage: u32 = 0,
    hIcon: HICON = null,
    /// Max tooltip length is 128 wchars incl. the terminator.
    szTip: [128]u16 = std.mem.zeroes([128]u16),
    dwState: u32 = 0,
    dwStateMask: u32 = 0,
    szInfo: [256]u16 = std.mem.zeroes([256]u16),
    /// NOTIFYICONDATAW unions uTimeout / uVersion over the same u32.
    uVersion: u32 = 0,
    szInfoTitle: [64]u16 = std.mem.zeroes([64]u16),
    dwInfoFlags: u32 = 0,
    guidItem: GUID = .{},
    hBalloonIcon: HICON = null,
};

// ---- window styles / frame ---------------------------------------------
pub const GWL_STYLE: c_int = -16;
pub const GWLP_WNDPROC: c_int = -4;
pub const GWLP_USERDATA: c_int = -12;
pub const WS_SYSMENU: usize = 0x0008_0000;
pub const WS_THICKFRAME: usize = 0x0004_0000;
/// Enables `ShowWindow(SW_MAXIMIZE)`: without it Win32 silently ignores the
/// maximize of a popup-style window (what the custom title bar's button does).
pub const WS_MAXIMIZEBOX: usize = 0x0001_0000;

pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_FRAMECHANGED: u32 = 0x0020;

/// "Non-client left button down": posted to the caption area to start the
/// native modal drag from custom chrome.
pub const WM_NCLBUTTONDOWN: u32 = 0x00A1;
/// Asks the window how much of a proposed rect is client area (the rest is
/// the non-client frame, which DWM paints itself).
pub const WM_NCCALCSIZE: u32 = 0x0083;
/// Asks where a screen point lands on the window (client area, edge, caption).
pub const WM_NCHITTEST: u32 = 0x0084;
/// Hit-test code for the caption (drag) area.
pub const HTCAPTION: usize = 2;
/// Hit-test codes for the sizing edges of a `WS_THICKFRAME` window.
pub const HTCLIENT: usize = 1;
pub const HTLEFT: usize = 10;
pub const HTRIGHT: usize = 11;
pub const HTTOP: usize = 12;
pub const HTTOPLEFT: usize = 13;
pub const HTTOPRIGHT: usize = 14;
pub const HTBOTTOM: usize = 15;
pub const HTBOTTOMLEFT: usize = 16;
pub const HTBOTTOMRIGHT: usize = 17;

/// A Win32 window procedure (same shape as `WNDCLASSEXW.lpfnWndProc`).
pub const WndProc = *const fn (HWND, u32, usize, isize) callconv(.c) isize;

pub const RECT = extern struct {
    left: c_long = 0,
    top: c_long = 0,
    right: c_long = 0,
    bottom: c_long = 0,
};

// ---- icon loading --------------------------------------------------------
pub const IMAGE_ICON: u32 = 1;
pub const LR_LOADFROMFILE: u32 = 0x0000_0010;
pub const LR_DEFAULTSIZE: u32 = 0x0000_0040;
pub const SM_CXICON: c_int = 11;
pub const SM_CYICON: c_int = 12;
pub const SM_CXSMICON: c_int = 49;
pub const SM_CYSMICON: c_int = 50;

// ---- messages ------------------------------------------------------------
pub const WM_NULL: u32 = 0x0000;
pub const WM_SETICON: u32 = 0x0080;
pub const WM_GETICON: u32 = 0x007F;
pub const ICON_SMALL: usize = 0;
pub const ICON_BIG: usize = 1;
pub const WM_APP: u32 = 0x8000;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_LBUTTONDBLCLK: u32 = 0x0203;
pub const WM_RBUTTONUP: u32 = 0x0205;
pub const WM_RBUTTONDBLCLK: u32 = 0x0206;

// ---- shell notification area (system tray) -------------------------------
pub const NIM_ADD: u32 = 0x0000_0000;
pub const NIM_MODIFY: u32 = 0x0000_0001;
pub const NIM_DELETE: u32 = 0x0000_0002;
pub const NIF_MESSAGE: u32 = 0x0000_0001;
pub const NIF_ICON: u32 = 0x0000_0002;
pub const NIF_TIP: u32 = 0x0000_0004;

// ---- popup menus ----------------------------------------------------------
pub const MF_STRING: u32 = 0x0000_0000;
pub const MF_GRAYED: u32 = 0x0000_0001;
pub const MF_SEPARATOR: u32 = 0x0000_0800;
pub const TPM_LEFTALIGN: u32 = 0x0000_0000;
pub const TPM_TOPALIGN: u32 = 0x0000_0000;
/// TrackPopupMenu returns the chosen item's id instead of a BOOL.
pub const TPM_RETURNCMD: u32 = 0x0000_0100;

// ---- window show state ----------------------------------------------------
pub const SW_HIDE: c_int = 0;
pub const SW_SHOW: c_int = 5;

/// The parent passed to CreateWindowExW for a message-only window: hidden,
/// never in the taskbar, receiving only messages directed at it - the ideal
/// callback target for a notification-area icon.
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(~@as(isize, 2))));

pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) isize;
pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: isize) isize;
pub extern "user32" fn SetWindowPos(
    hWnd: HWND,
    hWndInsertAfter: HWND,
    X: c_int,
    Y: c_int,
    cx: c_int,
    cy: c_int,
    uFlags: u32,
) c_int;
pub extern "user32" fn SendMessageW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) isize;
pub extern "user32" fn PostMessageW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) c_int;
pub extern "user32" fn GetSystemMetrics(nIndex: c_int) c_int;
pub extern "user32" fn LoadImageW(
    hInst: HMODULE,
    name: ?[*:0]const u16,
    uType: u32,
    cxDesired: c_int,
    cyDesired: c_int,
    fuLoad: u32,
) HANDLE;
pub extern "user32" fn DestroyIcon(hIcon: HICON) c_int;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) c_int;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) c_int;
/// Release the mouse capture, so a posted non-client message starts its own
/// modal loop instead of feeding our event queue.
pub extern "user32" fn ReleaseCapture() c_int;
/// The cursor position (screen coordinates, low word x) of the last message
/// retrieved from the queue - the lParam a non-client drag wants.
pub extern "user32" fn GetMessagePos() u32;
pub extern "user32" fn GetCursorPos(lpPoint: ?*POINT) c_int;
pub extern "user32" fn FindWindowW(lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16) HWND;
pub extern "user32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) HMODULE;
pub extern "user32" fn RegisterClassExW(lpwcx: ?*const WNDCLASSEXW) u16;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: u32,
    X: c_int,
    Y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: HWND,
    hMenu: HMENU,
    hInstance: HMODULE,
    lpParam: ?*anyopaque,
) HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) c_int;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) isize;
/// Forward a message to the window procedure a subclass replaced.
pub extern "user32" fn CallWindowProcW(
    lpPrevWndFunc: ?WndProc,
    hWnd: HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
) isize;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: ?*RECT) c_int;
/// Whether the window is currently maximized.
pub extern "user32" fn IsZoomed(hWnd: HWND) c_int;
pub extern "user32" fn CreatePopupMenu() HMENU;
pub extern "user32" fn AppendMenuW(
    hMenu: HMENU,
    uFlags: u32,
    idNewItem: usize,
    lpNewItem: ?[*:0]const u16,
) c_int;
pub extern "user32" fn TrackPopupMenu(
    hMenu: HMENU,
    uFlags: u32,
    x: c_int,
    y: c_int,
    nReserved: c_int,
    hWnd: HWND,
    prcRect: ?*anyopaque,
) c_int;
pub extern "user32" fn DestroyMenu(hMenu: HMENU) c_int;
pub extern "shell32" fn Shell_NotifyIconW(dwMessage: u32, pdata: ?*NOTIFYICONDATAW) c_int;
/// The path of the executable (or a module): what an app's assets sit next
/// to, whatever the working directory is.
pub extern "kernel32" fn GetModuleFileNameW(hModule: HMODULE, lpFilename: ?[*:0]u16, nSize: u32) u32;

/// An icon pair as Win32 wants it: a small one for the title bar and a big
/// one for Alt+Tab / the taskbar. Load it with `loadFile` (an .ico that
/// embeds several sizes is ideal) and release with `destroy`; an `Icon`
/// holds raw shared-by-handle values, copying it does not copy the handles.
pub const Icon = struct {
    small: HICON = null,
    big: HICON = null,

    /// Load an icon from a UTF-8 path to an .ico file (PNG / other formats
    /// are not supported by LoadImageW; ship an .ico with 16 and 32 bpp
    /// sizes inside). A relative path is searched relative to the executable
    /// directory first, then as given, so an icon installed next to the exe
    /// loads no matter what the working directory is. Returns
    /// `error.IconLoadFailed` when neither variant could be loaded.
    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !Icon {
        const candidates = exeRelativeCandidates(allocator, path) catch &.{path};

        for (candidates) |candidate| {
            if (iconFromPath(allocator, candidate)) |icon| {
                if (candidates.len > 1) allocator.free(candidates[0]);
                return icon;
            }
        }
        if (candidates.len > 1) allocator.free(candidates[0]);
        return error.IconLoadFailed;
    }

    fn iconFromPath(allocator: std.mem.Allocator, path: []const u8) ?Icon {
        const wpath = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return null;
        defer allocator.free(wpath);

        // Zero sizes mean "system metrics": 32-ish for the big icon and
        // 16-ish for the small one; LoadImageW picks the closest size the
        // .ico actually contains and scales if needed.
        const big = LoadImageW(
            null,
            wpath.ptr,
            IMAGE_ICON,
            GetSystemMetrics(SM_CXICON),
            GetSystemMetrics(SM_CYICON),
            LR_LOADFROMFILE,
        );
        const small = LoadImageW(
            null,
            wpath.ptr,
            IMAGE_ICON,
            GetSystemMetrics(SM_CXSMICON),
            GetSystemMetrics(SM_CYSMICON),
            LR_LOADFROMFILE,
        );
        if (big == null and small == null) return null;
        return .{ .small = small, .big = big };
    }

    /// `[exe_dir/path, path]` for a relative path (absolute paths come back
    /// unchanged from `join`); the second slot reuses the caller's slice.
    fn exeRelativeCandidates(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
        var wbuf: [1024]u16 = undefined;
        const len = GetModuleFileNameW(null, @ptrCast(&wbuf), wbuf.len);
        if (len == 0) return &.{path};
        const exe = std.unicode.utf16LeToUtf8Alloc(allocator, wbuf[0..len]) catch return &.{path};
        defer allocator.free(exe);
        const exe_dir = std.fs.path.dirname(exe) orelse return &.{path};
        const joined = try std.fs.path.join(allocator, &.{ exe_dir, path });
        const out = try allocator.alloc([]const u8, 2);
        out[0] = joined;
        out[1] = path;
        return out;
    }

    /// Release the handles loaded by `loadFile`; safe to call twice.
    pub fn destroy(self: *Icon) void {
        if (self.big) |h| _ = DestroyIcon(h);
        if (self.small) |h| _ = DestroyIcon(h);
        self.* = .{};
    }
};
