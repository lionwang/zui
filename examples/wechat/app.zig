//! The WeChat-style chat window: root component and window configuration.
//!
//! The layout mirrors WeChat for Windows: a dark navigation rail, a session
//! list and a chat area with message bubbles, an editable input and simulated
//! replies. Everything is drawn with zui primitives - the icons are vector
//! paths (`icons`), the avatars are colored rounded squares with a white
//! glyph - so the example needs no image assets beyond the window icon.

const std = @import("std");
const zui = @import("zui");
const ui = zui.widgets;
const Context = zui.Context;
const Element = zui.Element;

const theme = @import("theme.zig");
const data = @import("data.zig");
const nav_rail = @import("nav_rail.zig");
const session_list = @import("session_list.zig");
const chat_room = @import("chat_room.zig");
const c = theme.c;

const Store = data.Store;
const Nav = nav_rail.Nav;
const rail = nav_rail.rail;
const searchBar = session_list.searchBar;
const sessionBody = session_list.sessionBody;
const ChatRoom = chat_room.ChatRoom;

pub const WeChat = struct {
    pub const Props = void;

    pub fn render(ctx: *Context, props: Props) Element {
        _ = props;
        var store_h = ctx.useState(?Store, null);
        var current = ctx.useState(usize, 0);
        var nav = ctx.useState(Nav, .chat);
        const buffer = ctx.useState(ui.InputBuffer, .{});
        if (store_h.get() == null) {
            store_h.set(Store.make(ctx.node.allocator) catch unreachable);
        }
        const store = store_h.get().?;

        // 1.2.1 The tool menu: the frameless window's title bar (drag the
        // empty area, double-press to maximize) with minimize / maximize /
        // close buttons. It belongs to the right column, so the rail next to
        // it runs the full window height, like the real client. The bar
        // paints with the rail's mica color so the two blend into one
        // material, as the reference window does.
        const tool_menu = if (ctx.window) |win|
            ui.titleBarElement(ctx.arena, .{
                .window = win,
                .height = 32,
                .background = c.rail,
            })
        else
            ui.rect(ctx, .{ .style = .{ .height = 32, .flex_shrink = 0 } });

        return ui.row(ctx, .{
            // 1.1 The light navigation rail (left half of the window).
            .style = .{ .flex_grow = 1, .align_items = .stretch },
            .children = &.{
                rail(ctx, nav.ptr),
                // 1.2 The right half: tool menu on top...
                ui.column(ctx, .{
                    .style = .{ .flex_grow = 1, .align_items = .stretch },
                    .children = &.{
                        tool_menu,
                        // 1.2.2 ...and below it the session pane and the chat.
                        ui.row(ctx, .{
                            .style = .{ .flex_grow = 1, .align_items = .stretch },
                            .children = &.{
                                // 1.2.2.1 Sessions: search bar over the list.
                                ui.column(ctx, .{
                                    .style = .{
                                        .width = 240,
                                        .flex_shrink = 0,
                                        .background = c.panel,
                                        .align_items = .stretch,
                                    },
                                    .children = &.{
                                        searchBar(ctx),
                                        sessionBody(ctx, store, current.ptr, nav.get()),
                                    },
                                }),
                                // 1.2.2.2 The conversation and the input.
                                ctx.componentProps("chatRoom", ChatRoom.Props{
                                    .store = store,
                                    .idx = current.get(),
                                    .buffer = buffer,
                                }, ChatRoom.render),
                            },
                        }),
                    },
                }),
            },
        });
    }
};

/// Open the window and run the app until it closes.
pub fn run() !void {
    var application = try zui.App.init(std.heap.page_allocator, WeChat, {}, .{
        .title = "微信",
        .width = 1030,
        .height = 720,
        .background = c.chat_bg,
        // Frameless (no OS system menu / buttons). The title bar is rendered
        // inside the component tree, to the right of the full-height rail,
        // instead of full width at the top - see `WeChat.render`. The app
        // icon is installed next to the executable by build.zig.
        .system_menu = false,
        .title_bar = false,
        .icon = "wechat.ico",
    });
    defer application.deinit();
    try application.run();
}
