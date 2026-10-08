//! zui - a Skia based declarative UI library for Zig, inspired by Freya.
//!
//! Freya's stack maps onto zui like this:
//!   * dioxus (components + hooks) -> `element` + `context`
//!   * signals                  -> `signal` / `Context.useState`
//!   * skia                     -> `skia` (thin Zig bindings over the `zsk` C ABI)
//!   * taffy (flexbox)          -> `layout`
//!   * winit                    -> `window` (GLFW)
//!   * the renderer             -> `paint`
//!   * the event loop           -> `app`
//!
//! A zui app is a component: a struct with a `render` function that returns an
//! `Element` tree and reads/writes state through hooks.
//!
//! ```zig
//! const zui = @import("zui");
//! const ui = zui.widgets;
//!
//! pub const Counter = struct {
//!     pub fn render(ctx: *zui.Context, props: void) zui.Element {
//!         var count = ctx.useState(i32, 0);
//!         return ui.column(ctx, .{
//!             .style = .{ .gap = 12, .align_items = .center },
//!             .children = &.{
//!                 ui.text(.{ .font_size = 32 }, try std.fmt.allocPrint(ctx.arena, "{d}", .{count.get()})),
//!                 ui.button(ctx, .{ .label = "+1", .onclick = count.handler(...) }),
//!             },
//!         });
//!     }
//! };
//!
//! pub fn main() !void {
//!     try zui.launch(Counter, .{});
//! }
//! ```

const std = @import("std");

pub const skia = @import("skia.zig");
pub const window = @import("window.zig");
pub const events = @import("events.zig");
pub const element = @import("element.zig");
pub const context = @import("context.zig");
pub const signal = @import("signal.zig");
pub const node = @import("node.zig");
pub const reconcile = @import("reconcile.zig");
pub const layout = @import("layout/layout.zig");
pub const paint = @import("paint.zig");
pub const app = @import("app.zig");
pub const widgets = @import("widgets/widgets.zig");
pub const tray = @import("tray.zig");
/// Raw Win32 bindings (handles, icon loading, styles). Windows only; here
/// for power users - e.g. `zui.win32.Icon` to build an icon for
/// `Window.setIcon` from something other than `AppConfig.icon`.
pub const win32 = @import("win32.zig");

pub const Window = window.Window;
pub const Element = element.Element;
pub const Style = element.Style;
pub const Edges = element.Edges;
pub const Handler = element.Handler;
pub const Context = context.Context;
pub const State = context.State;
pub const App = app.App;
pub const AppConfig = app.AppConfig;
pub const Tray = tray.Tray;
pub const MenuItem = tray.MenuItem;

/// Ergonomic element constructors (`ui.column`, `ui.text`, ...).
pub const ui = widgets;

/// Launch an application whose root component is `Root`.
///
/// `Root` is a struct with an optional `pub const Props` and a
/// `pub fn render(ctx: *Context, props: Props) Element`.
pub fn launch(comptime Root: anytype, args: anytype) !void {
    // Normalize the props: `void` roots are called with `launch(Root, .{})`.
    const Props = if (@hasDecl(Root, "Props")) Root.Props else void;
    const props: Props = if (Props == void) {} else args;
    var application = try App.init(std.heap.page_allocator, Root, props, .{});
    defer application.deinit();
    try application.run();
}
