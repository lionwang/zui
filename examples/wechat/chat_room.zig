//! The chat area: header, scrollable message list with selectable
//! bubbles, and the input bar with simulated replies.

const std = @import("std");
const zui = @import("zui");
const ui = zui.widgets;
const element = zui.element;
const Context = zui.Context;
const Element = zui.Element;
const State = zui.State;

const theme = @import("theme.zig");
const icons = @import("icons.zig").icons;
const common = @import("common.zig");
const data = @import("data.zig");
const Session = data.Session;
const headerNameStyle = theme.headerNameStyle;
const Store = data.Store;
const avatar = common.avatar;
const iconButton = common.iconButton;
const filler = common.filler;
const toolIcon = common.toolIcon;
const quoteIcon = common.quoteIcon;
const txt = theme.txt;
const bubbleTextStyle = theme.bubbleTextStyle;
const c = theme.c;

const SendCtx = struct {
    store: Store,
    idx: usize,
    buffer: *ui.InputBuffer,
    pin: *u32,
    reply_at: *u64,
};

fn onSend(p: *anyopaque) void {
    const s: *SendCtx = @ptrCast(@alignCast(p));
    if (!s.buffer.hasContent()) return;
    const text = s.buffer.text();
    s.store.append(s.idx, text, true) catch return;
    s.buffer.items.clearRetainingCapacity();
    s.pin.* += 1;
    s.reply_at.* = zui.skia.millis() + 1400;
    s.store.setPreview(s.idx, text);
}

pub const ChatRoom = struct {
    pub const Props = struct {
        store: Store,
        idx: usize,
        buffer: State(ui.InputBuffer),
    };

    pub fn render(ctx: *Context, props: Props) Element {
        // A value copy: it shares the backing arrays with the root's store,
        // and being mutable lets `append` / `setPreview` take `*Store`.
        var store = props.store;
        const idx = props.idx;
        const session = &store.sessions[idx];
        const list = &store.msgs[idx];

        var pin = ctx.useState(u32, 0);
        var reply_at = ctx.useState(u64, 0);
        var reply_i = ctx.useState(usize, 0);
        var send = ctx.useState(SendCtx, undefined);
        send.set(.{
            .store = store,
            .idx = idx,
            .buffer = props.buffer.ptr,
            .pin = pin.ptr,
            .reply_at = reply_at.ptr,
        });

        // Land the simulated reply once its timer expired.
        if (reply_at.get() != 0 and zui.skia.millis() >= reply_at.get()) {
            reply_at.set(0);
            if (session.replies.len > 0) {
                const text = session.replies[reply_i.get() % session.replies.len];
                store.append(idx, text, false) catch {};
                store.setPreview(idx, text);
                reply_i.set(reply_i.get() + 1);
                pin.set(pin.get() + 1);
            }
        }

        var messages = ctx.arena.alloc(Element, list.items.len) catch unreachable;
        for (list.items, 0..) |it, i| {
            messages[i] = switch (it) {
                // Copy the slice out of the stack-local union payload: the
                // element tree is only read after this render returned.
                .time => |t| datePill(ctx, ctx.arena.dupe(u8, t.view()) catch ""),
                .msg => |m| messageRow(ctx, session, m.mine, m.text, i),
            };
        }

        const can_send = props.buffer.get().hasContent();

        // The emoji picker: the smiley in the tool row toggles it, picking a
        // cell appends the emoji to the composer buffer and closes it. One
        // `EmojiCtx` per cell lives in a hook so the click handlers (which
        // fire during the next event poll, after this frame's arena is gone)
        // point at stable storage.
        const emoji_open = ctx.useState(bool, false);
        var pickers = ctx.useState([emoji_grid.len]EmojiCtx, undefined);
        for (emoji_grid, 0..) |e, i| {
            pickers.ptr[i] = .{
                .buffer = props.buffer.ptr,
                .open = emoji_open.ptr,
                .alloc = ctx.node.allocator,
                .emoji = e,
            };
        }

        const header = ui.row(ctx, .{
            .style = .{
                .height = c.top_strip,
                .flex_shrink = 0,
                .background = c.header,
                .border = .{ .top = 0, .left = 0, .right = 0, .bottom = 1 },
                .border_color = c.header_border,
                .padding = .{ .left = 24, .right = 18 },
                .gap = 20,
                .align_items = .center,
            },
            .children = &.{
                ui.text(headerNameStyle(), session.name),
                filler(ctx),
                iconButton(ctx, &icons.person, c.icon_dark),
                iconButton(ctx, &icons.video, c.icon_dark),
                iconButton(ctx, &icons.dots_h, c.icon_dark),
            },
        });
        const message_list = ui.column(ctx, .{
            .style = .{
                .flex_grow = 1,
                .align_items = .stretch,
                .scroll = .{ .pin = .bottom, .anchor = @intCast(list.items.len) },
                .padding = .{ .left = 24, .right = 22, .top = 8, .bottom = 14 },
                .gap = 12,
            },
            .children = messages,
        });
        // The composer: a floating rounded card inset from the chat
        // column's edges (the reference's input box is a panel with a
        // 6px left / 8px right margin, a #EAEAEA border and a soft
        // shadow, not a full-bleed slab), and stopped 3px short of the
        // window's bottom edge. The editor fills the top (typed text
        // lands top-left, the caret blinks WeChat green); the 28px tool
        // row below mirrors the reference icon for icon: smiley, file
        // and reply on the left, clock and 发送 pinned right, at the
        // measured pitches. The card itself is not focusable: a click
        // on its dead space leaves the focus with the editor
        // (`sticky_focus`), so the caret stays and typing keeps flowing.
        const card = ui.column(ctx, .{
            .style = .{
                .flex_shrink = 0,
                .height = c.composer_h,
                .background = c.input_bg,
                .border = .{ .top = 2, .left = 1, .right = 1, .bottom = 2 },
                .border_color = c.composer_border,
                .border_radius = c.composer_radius,
                .overflow = .hidden,
                .padding = .{ .bottom = 6 },
                .align_items = .stretch,
            },
            .children = &.{
                ui.textInput(ctx, .{
                    .style = .{
                        .flex_grow = 1,
                        .padding = .{ .top = 17, .left = 12, .bottom = 3 },
                        .background = 0,
                        .color = c.text_primary,
                        .font_size = 14,
                        .font_family = c.font,
                        .line_height = 1.35,
                    },
                    .placeholder = "",
                    .buffer = props.buffer,
                    .caret_color = c.caret,
                    .onsubmit = .{ .func = onSend, .data = send.ptr },
                }),
                // The tool row: slots of the reference's exact widths
                // (37/31/13, then the right group 33/48) with the icons
                // parked at their left edges - the pitches are not
                // uniform, so a single gap cannot express them.
                ui.row(ctx, .{
                    .style = .{
                        .flex_shrink = 0,
                        .height = c.toolbar_h,
                        .padding = .{ .left = 13, .right = 10 },
                        .align_items = .center,
                    },
                    .children = &.{
                        toolSlot(ctx, 37, toolIcon(ctx, 18, 18, &icons.smile_line, c.toolbar_icon, emoji_open.handler(toggleOpen))),
                        toolSlot(ctx, 31, toolIcon(ctx, 18, 18, &icons.file_line, c.toolbar_icon, null)),
                        toolSlot(ctx, 13, quoteIcon(ctx, c.toolbar_icon, null)),
                        filler(ctx),
                        toolSlot(ctx, 33, toolIcon(ctx, 18, 18, &icons.clock_line, c.toolbar_icon, null)),
                        ui.rect(ctx, .{
                            .style = .{
                                .width = 48,
                                .height = 26,
                                .flex_shrink = 0,
                                .border_radius = 4,
                                .background = if (can_send) c.send else c.send_disabled,
                                .align_items = .center,
                                .justify_content = .center,
                            },
                            .cursor = if (can_send) .hand else .arrow,
                            .onclick = if (can_send) .{ .func = onSend, .data = send.ptr } else null,
                            .children = &.{ui.text(
                                txt(12, if (can_send) 0xFFFFFFFF else c.send_disabled_text),
                                "发送",
                            )},
                        }),
                    },
                }),
            },
        });
        const composer = ui.rect(ctx, .{
            .style = .{
                .flex_shrink = 0,
                .padding = .{
                    .left = c.composer_inset_left,
                    .right = c.composer_inset_right,
                    .bottom = c.composer_bottom_gap,
                },
            },
            .children = &.{
                // The card's drop shadow: two low-alpha halos behind it
                // (the reference's edge fade is ~3% over 6px), stacked
                // loose/tight to fake the gradient without a blur pass.
                // They reach down into the 3px strip under the card.
                ui.rect(ctx, .{
                    .style = .{
                        .position = .absolute,
                        .left = -5,
                        .right = -5,
                        .top = 0,
                        .bottom = -3 - c.composer_bottom_gap,
                        .border_radius = 9,
                        .background = 0x06000000,
                    },
                }),
                ui.rect(ctx, .{
                    .style = .{
                        .position = .absolute,
                        .left = -2,
                        .right = -2,
                        .top = 0,
                        .bottom = -1,
                        .border_radius = 7,
                        .background = 0x0A000000,
                    },
                }),
                card,
            },
        });

        // While the picker is open, a transparent catcher fills the chat
        // column *under* the composer but over the header and message list
        // (a click anywhere on those closes the panel), and the picker layer
        // comes last, above the composer: a click on a cell never lands on
        // the editor underneath it.
        var chat_children = ctx.arena.alloc(Element, 5) catch unreachable;
        var n: usize = 0;
        chat_children[n] = header;
        n += 1;
        chat_children[n] = message_list;
        n += 1;
        if (emoji_open.get()) {
            chat_children[n] = ui.rect(ctx, .{
                .style = .{
                    .position = .absolute,
                    .left = 0,
                    .top = 0,
                    .right = 0,
                    .bottom = 0,
                },
                .cursor = .arrow,
                .onclick = emoji_open.handler(closeOpen),
            });
            n += 1;
        }
        chat_children[n] = composer;
        n += 1;
        if (emoji_open.get()) {
            chat_children[n] = emojiLayer(ctx, pickers.ptr);
            n += 1;
        }

        return ui.column(ctx, .{
            .style = .{ .flex_grow = 1, .align_items = .stretch, .background = c.chat_bg },
            .children = chat_children[0..n],
        });
    }
};

pub const emoji_cols = 8;
pub const emoji_grid = [_][]const u8{
    "😀",
    "😂",
    "🥰",
    "😊",
    "😍",
    "😘",
    "😎",
    "🤔",
    "👍",
    "👌",
    "🙏",
    "💪",
    "🎉",
    "💙",
    "🔥",
    "⭐",
    "😅",
    "😢",
    "😡",
    "🥳",
    "😴",
    "🤣",
    "👏",
    "🌹",
};

/// One picker cell's click context: the shared buffer / open state plus
/// the emoji to append. The array of these lives in a ChatRoom hook, so
/// the click handlers (which fire during the next event poll, after this
/// frame's arena is gone) point at stable storage.
const EmojiCtx = struct {
    buffer: *ui.InputBuffer,
    open: *bool,
    alloc: std.mem.Allocator,
    emoji: []const u8,
};

fn toggleOpen(p: *bool) void {
    p.* = !p.*;
}

fn closeOpen(p: *bool) void {
    p.* = false;
}

/// A fixed-width parking slot for a tool-row icon: the icon sits at the
/// slot's left edge, so the row's icon pitches are decided by the slot
/// widths (not uniform: 37/35/31/57/13 on the left, 33/48 on the right),
/// exactly as measured off the reference.
fn toolSlot(ctx: *Context, w: f32, icon: Element) Element {
    return ui.rect(ctx, .{
        .style = .{ .width = w, .flex_shrink = 0, .align_items = .flex_start },
        .children = &.{icon},
    });
}

fn onPick(p: *anyopaque) void {
    const s: *EmojiCtx = @ptrCast(@alignCast(p));
    s.buffer.items.appendSlice(s.alloc, s.emoji) catch {};
    s.open.* = false;
}

/// The floating emoji grid: an absolutely positioned white panel above the
/// composer, left-aligned with the smiley that opens it.
fn emojiLayer(ctx: *Context, pickers: *[emoji_grid.len]EmojiCtx) Element {
    const rows_n = (emoji_grid.len + emoji_cols - 1) / emoji_cols;
    var rows = ctx.arena.alloc(Element, rows_n) catch unreachable;
    var r: usize = 0;
    while (r < rows_n) : (r += 1) {
        var cells = ctx.arena.alloc(Element, emoji_cols) catch unreachable;
        var col: usize = 0;
        while (col < emoji_cols) : (col += 1) {
            const idx = r * emoji_cols + col;
            cells[col] = ui.rect(ctx, .{
                .style = .{
                    .width = 38,
                    .height = 38,
                    .flex_shrink = 0,
                    .align_items = .center,
                    .justify_content = .center,
                    .border_radius = 6,
                },
                .cursor = .hand,
                .onclick = .{ .func = onPick, .data = &pickers[idx] },
                .children = &.{ui.text(txt(22, c.text_primary), emoji_grid[idx])},
            });
        }
        rows[r] = ui.row(ctx, .{
            .style = .{ .flex_shrink = 0, .gap = 2 },
            .children = cells,
        });
    }
    return ui.rect(ctx, .{
        .style = .{
            .position = .absolute,
            .left = c.composer_pad,
            .bottom = c.composer_h + 6 + c.composer_bottom_gap,
            .background = c.emoji_panel,
            .border = .all(1),
            .border_color = c.emoji_panel_border,
            .border_radius = 8,
            .padding = .all(6),
            .gap = 4,
            .direction = .column,
            .align_items = .flex_start,
        },
        .children = rows,
    });
}

fn datePill(ctx: *Context, text: []const u8) Element {
    return ui.rect(ctx, .{
        .style = .{
            .align_self = .center,
            .height = 22,
            .flex_shrink = 0,
            .background = c.pill,
            .border_radius = 4,
            .padding = .{ .left = 10, .right = 10 },
            .align_items = .center,
            .justify_content = .center,
        },
        .children = &.{ui.text(txt(12, c.pill_text), text)},
    });
}

/// The bubble tails, traced off the reference screenshot (measured, not
/// guessed): a small blunt beak at the bubble's vertical mid-height, flush
/// against its edge - left-pointing on received bubbles (6x10), right-pointing
/// on sent ones (5x8, depth profile ~2,3,4,4,4,3,2). The apex is a quad arc,
/// not a spike, and the two flanks curve out of a straight base edge.
/// Coordinates are pre-distorted into the square 24x24 view space because the
/// painter scales x and y independently (w/24, h/24); multiplying the design
/// pixel coordinates by 24/width and 24/height lands them back on exact pixels.
pub const nub_left = [_]element.PathOp{
    .{ .move_to = .{ .x = 24, .y = 0 } },
    .{ .quad_to = .{ .c = .{ .x = 8.64, .y = 0 }, .p = .{ .x = 4.32, .y = 8.64 } } },
    .{ .quad_to = .{ .c = .{ .x = 0.96, .y = 12 }, .p = .{ .x = 4.32, .y = 15.36 } } },
    .{ .quad_to = .{ .c = .{ .x = 8.64, .y = 24 }, .p = .{ .x = 24, .y = 24 } } },
    .{ .close = {} },
};

pub const nub_right = [_]element.PathOp{
    .{ .move_to = .{ .x = 0, .y = 0 } },
    .{ .quad_to = .{ .c = .{ .x = 14.4, .y = 0 }, .p = .{ .x = 16.32, .y = 4.5 } } },
    // The apex control sits past the view edge on purpose: it bows the arc
    // out into a stubby flat apex (the reference's profiles hold the full
    // depth for three rows instead of tapering to a point).
    .{ .quad_to = .{ .c = .{ .x = 25.92, .y = 12 }, .p = .{ .x = 16.32, .y = 19.5 } } },
    .{ .quad_to = .{ .c = .{ .x = 14.4, .y = 24 }, .p = .{ .x = 0, .y = 24 } } },
    .{ .close = {} },
};

/// One message: a selectable, copyable text bubble. It is a component (keyed
/// by its index in the session) so each bubble owns its selection state.
fn messageRow(ctx: *Context, session: *const Session, mine: bool, text: []const u8, index: usize) Element {
    var el = ctx.componentProps("messageRow", MessageRow.Props{
        .session = session,
        .mine = mine,
        .text = text,
    }, MessageRow.render);
    // Keyed by index: the selection state sticks to the message even when
    // replies append to the list.
    if (el == .component) {
        el.component.key = std.fmt.allocPrint(ctx.arena, "msg{d}", .{index}) catch null;
    }
    return el;
}

const MessageRow = struct {
    pub const Props = struct {
        session: *const Session,
        mine: bool,
        text: []const u8,
    };

    pub fn render(ctx: *Context, props: Props) Element {
        // Drag to select, Ctrl+A / Ctrl+C to copy; the click moves the focus
        // here, so typing goes back to the input after clicking it.
        const sel = ui.textSelection(ctx, props.text);

        const bubble_color: u32 = if (props.mine) c.bubble_me else c.bubble_other;
        // The tail: a small blunt beak flush against the bubble's edge at
        // its vertical middle (the reference's tails sit at mid-height, not
        // the corner). It shares a gap-0 row with the bubble so the base
        // touches it, and stretches to the bubble's height so the shape can
        // center on it.
        const nub_w: f32 = if (props.mine) 5 else 6;
        const nub_h: f32 = if (props.mine) 8 else 10;
        const nub = ui.rect(ctx, .{
            .style = .{
                .width = nub_w,
                .flex_shrink = 0,
                .align_items = .center,
                .justify_content = .center,
            },
            .children = &.{ui.shape(ctx, .{
                .style = .{ .width = nub_w, .height = nub_h, .background = bubble_color },
                .ops = if (props.mine) &nub_right else &nub_left,
            })},
        });

        var label_style = bubbleTextStyle();
        label_style.selection = sel.state.selectionStyle();
        const bubble = ui.rect(ctx, .{
            .style = .{
                .background = bubble_color,
                .border_radius = 6,
                .max_width = 480,
                .flex_shrink = 0,
                .padding = .{ .left = 12, .right = 12, .top = 9, .bottom = 9 },
            },
            .cursor = .ibeam,
            .focusable = true,
            .onkey = sel.onkey,
            .onmouse = sel.onmouse,
            .children = &.{ui.text(label_style, props.text)},
        });

        if (props.mine) {
            return ui.row(ctx, .{
                .style = .{ .align_items = .flex_start, .gap = 8, .flex_shrink = 0, .justify_content = .flex_end },
                .children = &.{
                    // The beak's base touches the bubble's right edge.
                    ui.row(ctx, .{
                        .style = .{ .gap = 0, .flex_shrink = 0, .align_items = .stretch },
                        .children = &.{ bubble, nub },
                    }),
                    mineAvatar(ctx),
                },
            });
        }
        return ui.row(ctx, .{
            .style = .{ .align_items = .flex_start, .gap = 8, .flex_shrink = 0 },
            .children = &.{
                avatar(ctx, props.session, 36),
                // The beak's base touches the bubble's left edge.
                ui.row(ctx, .{
                    .style = .{ .gap = 0, .flex_shrink = 0, .align_items = .stretch },
                    .children = &.{ nub, bubble },
                }),
            },
        });
    }
};

fn mineAvatar(ctx: *Context) Element {
    return ui.rect(ctx, .{
        .style = .{
            .width = 36,
            .height = 36,
            .flex_shrink = 0,
            .border_radius = 7,
            .background = c.rail_avatar,
            .align_items = .center,
            .justify_content = .center,
        },
        .children = &.{ui.shape(ctx, .{
            .style = .{ .width = 22, .height = 22, .background = 0xFFFFFFFF },
            .ops = &icons.person,
        })},
    });
}

// ----------------------------------------------------------------------
// Root
// ----------------------------------------------------------------------
