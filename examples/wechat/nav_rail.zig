//! The light navigation rail (WeChat 4.0) with its icon buttons.

const zui = @import("zui");
const ui = zui.widgets;
const element = zui.element;
const Context = zui.Context;
const Element = zui.Element;

const theme = @import("theme.zig");
const icons = @import("icons.zig").icons;
const common = @import("common.zig");
const iconButton = common.iconButton;
const c = theme.c;
const filler = common.filler;

pub const Nav = enum {
    chat,
    contacts,
    favorites,
    files,
    moments,
    miniprogram,
    settings,
    more,
};

pub fn navIcon(nav: Nav) []const element.PathOp {
    return switch (nav) {
        .chat => &icons.chat,
        .contacts => &icons.person,
        .favorites => &icons.star,
        .files => &icons.folder,
        .moments => &icons.camera,
        .miniprogram => &icons.grid,
        .settings => &icons.settings,
        .more => &icons.dots_v,
    };
}

const NavSelect = struct {
    nav: *Nav,
    target: Nav,
};

const RailButton = struct {
    const Props = struct {
        target: Nav,
        active: bool,
        onselect: *NavSelect,
    };

    pub fn render(ctx: *Context, props: Props) Element {
        var hover = ctx.useState(bool, false);
        var sel = ctx.useState(NavSelect, undefined);
        sel.set(props.onselect.*);

        return ui.rect(ctx, .{
            .style = .{
                .width = 40,
                .height = 40,
                .flex_shrink = 0,
                .align_items = .center,
                .justify_content = .center,
                .border_radius = 6,
                .background = if (hover.get()) c.rail_hover else 0,
            },
            .cursor = .hand,
            .onclick = sel.handler(struct {
                fn run(p: *NavSelect) void {
                    p.nav.* = p.target;
                }
            }.run),
            .onmouseenter = hover.handler(struct {
                fn enter(p: *bool) void {
                    p.* = true;
                }
            }.enter),
            .onmouseleave = hover.handler(struct {
                fn leave(p: *bool) void {
                    p.* = false;
                }
            }.leave),
            .children = &.{
                ui.shape(ctx, .{
                    .style = .{ .width = 22, .height = 22, .background = if (props.active) c.rail_icon_active else c.rail_icon },
                    .ops = navIcon(props.target),
                }),
            },
        });
    }
};

pub fn rail(ctx: *Context, nav: *Nav) Element {
    const top: [5]Nav = .{ .chat, .contacts, .favorites, .files, .moments };
    const bottom: [3]Nav = .{ .miniprogram, .settings, .more };

    var children = ctx.arena.alloc(Element, 2 + top.len + 1 + bottom.len) catch unreachable;
    var k: usize = 0;
    children[k] = ui.rect(ctx, .{
        .style = .{
            .width = 36,
            .height = 36,
            .flex_shrink = 0,
            .border_radius = 8,
            .background = c.rail_avatar,
            .align_items = .center,
            .justify_content = .center,
        },
        .children = &.{ui.shape(ctx, .{
            .style = .{ .width = 20, .height = 20, .background = 0xFFFFFFFF },
            .ops = &icons.person,
        })},
    });
    k += 1;
    children[k] = ui.rect(ctx, .{ .style = .{ .width = 1, .height = 16, .flex_shrink = 0 } });
    k += 1;
    for (top) |n| {
        var sel = ctx.useState(NavSelect, undefined);
        sel.set(.{ .nav = nav, .target = n });
        children[k] = ctx.componentProps("railButton", RailButton.Props{
            .target = n,
            .active = nav.* == n,
            .onselect = sel.ptr,
        }, RailButton.render);
        k += 1;
    }
    children[k] = filler(ctx);
    k += 1;
    for (bottom) |n| {
        var sel = ctx.useState(NavSelect, undefined);
        sel.set(.{ .nav = nav, .target = n });
        children[k] = ctx.componentProps("railButton", RailButton.Props{
            .target = n,
            .active = nav.* == n,
            .onselect = sel.ptr,
        }, RailButton.render);
        k += 1;
    }

    return ui.column(ctx, .{
        .style = .{
            .width = 58,
            .flex_shrink = 0,
            .background = c.rail,
            .align_items = .center,
            .gap = 8,
            .padding = .{ .top = 42, .bottom = 16 },
        },
        .children = children,
    });
}

// ----------------------------------------------------------------------
// Session list
// ----------------------------------------------------------------------
