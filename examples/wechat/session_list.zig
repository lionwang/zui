//! The session list: search box, session rows with unread badges,
//! and the per-row select state.

const std = @import("std");
const zui = @import("zui");
const ui = zui.widgets;
const element = zui.element;
const Context = zui.Context;
const Element = zui.Element;
const State = zui.State;

const theme = @import("theme.zig");
const common = @import("common.zig");
const nav_rail = @import("nav_rail.zig");
const icons = @import("icons.zig").icons;
const data = @import("data.zig");
const Session = data.Session;
const Store = data.Store;
const Nav = nav_rail.Nav;
const avatar = common.avatar;
const txt = theme.txt;
const nameStyle = theme.nameStyle;
const previewStyle = theme.previewStyle;
const navIcon = nav_rail.navIcon;
const c = theme.c;

const SessionSelect = struct {
    current: *usize,
    idx: usize,
};

const SessionItem = struct {
    pub const Props = struct {
        session: *const Session,
        idx: usize,
        selected: bool,
        onselect: *SessionSelect,
    };

    pub fn render(ctx: *Context, props: Props) Element {
        var hover = ctx.useState(bool, false);
        var sel = ctx.useState(SessionSelect, undefined);
        sel.set(props.onselect.*);

        const s = props.session;
        const badge_w: f32 = if (s.unread > 9) 24 else 17;
        const badge_label = if (s.unread == 0)
            ""
        else if (s.unread > 99)
            "99+"
        else
            std.fmt.allocPrint(ctx.arena, "{d}", .{s.unread}) catch "";

        return ui.rect(ctx, .{
            .style = .{
                .height = 64,
                .flex_shrink = 0,
                .background = if (props.selected)
                    c.item_selected
                else if (hover.get())
                    c.item_hover
                else
                    0,
                // The hairline separator between sessions.
                .border = .{ .top = 0, .left = 0, .right = 0, .bottom = 1 },
                .border_color = c.item_separator,
            },
            .cursor = .hand,
            .onclick = sel.handler(struct {
                fn run(p: *SessionSelect) void {
                    p.current.* = p.idx;
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
                ui.row(ctx, .{
                    .style = .{
                        .padding = .{ .left = 16, .right = 14, .top = 12, .bottom = 12 },
                        .gap = 10,
                        .align_items = .flex_start,
                    },
                    .children = &.{
                        // The badge rides the avatar's top-right corner.
                        ui.rect(ctx, .{
                            .style = .{ .width = 36, .height = 36, .flex_shrink = 0 },
                            .children = &.{
                                avatar(ctx, s, 36),
                                if (s.unread > 0) ui.rect(ctx, .{
                                    .style = .{
                                        .position = .absolute,
                                        .right = -5,
                                        .top = -5,
                                        .width = badge_w,
                                        .height = 17,
                                        .flex_shrink = 0,
                                        .border_radius = 8.5,
                                        .background = c.badge,
                                        .align_items = .center,
                                        .justify_content = .center,
                                    },
                                    .children = &.{ui.text(txt(10, 0xFFFFFFFF), badge_label)},
                                }) else .{ .none = {} },
                            },
                        }),
                        ui.column(ctx, .{
                            .style = .{ .gap = 6, .flex_grow = 1 },
                            .children = &.{
                                // name + time
                                ui.row(ctx, .{
                                    .style = .{ .gap = 8, .align_items = .flex_start },
                                    .children = &.{
                                        ui.text(nameStyle(), s.name),
                                        ui.text(txt(12, c.text_secondary).with(.{
                                            .flex_shrink = 0,
                                        }), s.time.view()),
                                    },
                                }),
                                // preview + unread badge
                                ui.row(ctx, .{
                                    .style = .{ .gap = 6, .align_items = .flex_start },
                                    .children = &.{
                                        ui.text(previewStyle(), s.last[0..s.last_len]),
                                        if (s.unread > 0) ui.rect(ctx, .{
                                            .style = .{
                                                .width = badge_w,
                                                .height = 17,
                                                .flex_shrink = 0,
                                                .border_radius = 8.5,
                                                .background = c.badge,
                                                .align_items = .center,
                                                .justify_content = .center,
                                            },
                                            .children = &.{ui.text(txt(10, 0xFFFFFFFF), badge_label)},
                                        }) else .{ .none = {} },
                                    },
                                }),
                            },
                        }),
                    },
                }),
            },
        });
    }
};

/// 1.2.2.1.1 The conversation search bar: a padded strip holding the
/// search pill, an editable field with the magnifier as a suffix icon.
pub fn searchBar(ctx: *Context) Element {
    const search = ctx.useState(ui.InputBuffer, .{});
    return ui.rect(ctx, .{
        .style = .{
            // Explicit so the strip cannot drift from the chat header it
            // must line up with (12 + 25 + 11 = `c.top_strip`).
            .height = c.top_strip,
            .flex_shrink = 0,
            .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 11 },
        },
        .children = &.{searchPill(ctx, search)},
    });
}

/// The pill is a row holding the editable field (which grows) and the
/// magnifier as its suffix. Not autofocused: the chat input is the primary
/// target, clicking the field focuses it so typing flows in. The reference
/// search box has no border - it is the white #FAFAFA on the #EEEef0 pane.
fn searchPill(ctx: *Context, buffer: State(ui.InputBuffer)) Element {
    return ui.row(ctx, .{
        .style = .{
            .height = 25,
            .gap = 6,
            .padding = .{ .left = 8, .right = 8 },
            .background = c.panel_search,
            .border_radius = 4,
            .align_items = .center,
            .overflow = .hidden,
        },
        .children = &.{
            ui.textInput(ctx, .{
                .style = .{
                    .flex_grow = 1,
                    .color = c.text_secondary,
                    .font_size = 13,
                    .font_family = c.font,
                    .padding = .{},
                    .background = 0,
                },
                .placeholder = "搜索",
                .buffer = buffer,
                .autofocus = false,
                // A transient field: it loses the focus when the user clicks
                // anywhere else (the chat composer is the sticky one).
                .sticky_focus = false,
            }),
            ui.shape(ctx, .{
                .style = .{ .width = 14, .height = 14, .background = c.text_secondary, .flex_shrink = 0 },
                .ops = &icons.search,
                .fill = false,
                .stroke_width = 1.8,
            }),
        },
    });
}

/// 1.2.2.1.2 The session list itself (or the empty state of whichever rail
/// button is active; only the chat view is fleshed out).
pub fn sessionBody(ctx: *Context, store: Store, current: *usize, nav: Nav) Element {
    const items = items: {
        var list = ctx.arena.alloc(Element, store.sessions.len) catch unreachable;
        for (store.sessions, 0..) |*s, i| {
            var sel = ctx.useState(SessionSelect, undefined);
            sel.set(.{ .current = current, .idx = i });
            list[i] = ctx.componentProps("sessionItem", SessionItem.Props{
                .session = s,
                .idx = i,
                .selected = i == current.*,
                .onselect = sel.ptr,
            }, SessionItem.render);
        }
        break :items list;
    };

    // The panel body changes with the active rail button; only the chat view
    // is fleshed out, the other tabs show an empty state.
    return switch (nav) {
        .chat => ui.column(ctx, .{
            .style = .{
                .flex_grow = 1,
                .align_items = .stretch,
                .scroll = .{ .pin = .top, .anchor = 0 },
            },
            .children = items,
        }),
        else => ui.column(ctx, .{
            .style = .{
                .flex_grow = 1,
                .align_items = .center,
                .justify_content = .center,
                .gap = 12,
            },
            .children = &.{
                ui.shape(ctx, .{
                    .style = .{ .width = 40, .height = 40, .background = 0xFFC8C8C8 },
                    .ops = navIcon(nav),
                }),
                ui.text(txt(13, c.text_secondary), "暂无内容"),
            },
        }),
    };
}

// ----------------------------------------------------------------------
// Chat area
// ----------------------------------------------------------------------
