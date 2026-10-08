//! Structural components: tab bars and accordions.
//!
//! `tabs` keeps its selection in a caller-owned `State(u32)`; accordion
//! sections each own their open state, so any number can be open.

const std = @import("std");
const element = @import("../element.zig");
const context = @import("../context.zig");
const skia = @import("../skia.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const util = @import("util.zig");

// ----------------------------------------------------------------------
// Tabs
// ----------------------------------------------------------------------

pub const TabsArgs = struct {
    style: element.Style = .{},
    selected: context.State(u32),
    labels: []const []const u8,
    /// One pane per label; only the selected pane is rendered.
    children: []const element.Element,
    key: ?[]const u8 = null,
};

/// A tab bar with an underline on the active tab, and the selected pane
/// below it.
pub fn tabs(ctx: *context.Context, args: TabsArgs) element.Element {
    // The panes come from the caller's render frame: deep-copy them, since
    // the props box is only read later, during reconciliation.
    return ctx.componentProps("tabs", Tabs.Props{
        .style = args.style,
        .selected = args.selected,
        .labels = args.labels,
        .children = util.dupElements(ctx.arena, args.children) catch
            @panic("zui: out of memory while building the element tree"),
        .key = args.key,
    }, Tabs.render);
}

const Tabs = struct {
    const Props = struct {
        style: element.Style,
        selected: context.State(u32),
        labels: []const []const u8,
        children: []const element.Element,
        key: ?[]const u8,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        const tab_btns = ctx.arena.alloc(element.Element, props.labels.len) catch
            @panic("zui: out of memory while building the element tree");
        for (props.labels, 0..) |label, i| {
            tab_btns[i] = ctx.componentProps("tab", TabProps{
                .label = label,
                .selected = props.selected,
                .index = @as(u32, @intCast(i)),
            }, tabRender);
        }

        const bar = element.Element{ .rect = .{
            .style = .{
                .direction = .row,
                .gap = 2,
                .border = .{ .bottom = 1 },
                .border_color = t.border,
                .flex_shrink = 0,
            },
            .children = tab_btns,
        } };

        var style = element.Style{ .direction = .column };
        util.applyUser(&style, props.style);

        const sel = props.selected.get();
        const pane = if (sel < props.children.len) props.children[sel] else element.Element{ .none = {} };
        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = ctx.arena.dupe(element.Element, &.{ bar, pane }) catch
                @panic("zui: out of memory while building the element tree"),
        } };
    }
};

/// One tab: its own hook carries the shared selection pointer, the index
/// and a hover flag.
const TabState = struct {
    selected: ?*u32 = null,
    index: u32 = 0,
    hot: bool = false,
};
const TabProps = struct {
    label: []const u8 = "",
    selected: context.State(u32),
    index: u32 = 0,
};

fn tabRender(ctx: *context.Context, props: TabProps) element.Element {
    const t = theme.active;
    var st = ctx.useState(TabState, .{});
    st.ptr.selected = props.selected.ptr;
    st.ptr.index = props.index;

    const is_sel = if (st.ptr.selected) |s| (s.* == props.index) else false;
    return element.Element{ .rect = .{
        .style = .{
            .direction = .row,
            .align_items = .center,
            .justify_content = .center,
            .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 },
            .border = if (is_sel) .{ .bottom = 2 } else .{},
            .border_color = t.primary,
            .background = if (st.ptr.hot and !is_sel) t.muted else 0,
            .flex_shrink = 0,
        },
        .children = util.dupElements(ctx.arena, &.{
            .{ .text = .{
                .style = .{
                    .color = if (is_sel) t.primary else (if (st.ptr.hot) t.foreground else t.muted_foreground),
                    .font_size = 13,
                    .font_weight = if (is_sel) .medium else .normal,
                },
                .content = props.label,
            } },
        }) catch @panic("zui: out of memory while building the element tree"),
        .onclick = .{ .func = onPickTab, .data = st.ptr },
        .onmouseenter = .{ .func = onHoverTab, .data = st.ptr },
        .onmouseleave = .{ .func = onLeaveTab, .data = st.ptr },
        .cursor = .hand,
    } };
}

fn onPickTab(p: *anyopaque) void {
    const st: *TabState = @ptrCast(@alignCast(p));
    if (st.selected) |s| s.* = st.index;
}

fn onHoverTab(p: *anyopaque) void {
    const st: *TabState = @ptrCast(@alignCast(p));
    st.hot = true;
}

fn onLeaveTab(p: *anyopaque) void {
    const st: *TabState = @ptrCast(@alignCast(p));
    st.hot = false;
}

// ----------------------------------------------------------------------
// Accordion
// ----------------------------------------------------------------------

pub const AccordionItem = struct {
    title: []const u8,
    content: element.Element,
};

pub const AccordionArgs = struct {
    style: element.Style = .{},
    items: []const AccordionItem,
    key: ?[]const u8 = null,
};

/// A stack of independently collapsible sections.
pub fn accordion(ctx: *context.Context, args: AccordionArgs) element.Element {
    // Same lifetime rule as `tabs`: the section contents come from the
    // caller's frame, so deep-copy them before boxing the props.
    const items = ctx.arena.alloc(AccordionItem, args.items.len) catch
        @panic("zui: out of memory while building the element tree");
    for (args.items, 0..) |it, i| {
        items[i] = .{
            .title = it.title,
            .content = util.dupElement(ctx.arena, it.content) catch
                @panic("zui: out of memory while building the element tree"),
        };
    }
    return ctx.componentProps("accordion", Accordion.Props{
        .style = args.style,
        .items = items,
        .key = args.key,
    }, Accordion.render);
}

const Accordion = struct {
    const Props = struct {
        style: element.Style,
        items: []const AccordionItem,
        key: ?[]const u8,
    };

    fn render(ctx: *context.Context, props: Props) element.Element {
        const t = theme.active;
        const sections = ctx.arena.alloc(element.Element, props.items.len) catch
            @panic("zui: out of memory while building the element tree");
        for (props.items, 0..) |item, i| {
            sections[i] = ctx.componentProps("accordionSection", SectionProps{
                .title = item.title,
                .content = item.content,
                .last = i + 1 == props.items.len,
            }, accordionSection);
        }
        var style = element.Style{
            .direction = .column,
            .border = .all(1),
            .border_color = t.border,
            .border_radius = 8,
            .overflow = .hidden,
        };
        util.applyUser(&style, props.style);
        return element.Element{ .rect = .{
            .key = props.key,
            .style = style,
            .children = sections,
        } };
    }
};

const SectionProps = struct {
    title: []const u8 = "",
    content: element.Element = .{ .none = {} },
    last: bool = false,
};

fn accordionSection(ctx: *context.Context, props: SectionProps) element.Element {
    const t = theme.active;
    var open = ctx.useState(bool, false);

    const chevron_ops = if (open.get()) &icons.chevron_up else &icons.chevron_down;
    const header = element.Element{ .rect = .{
        .style = .{
            .direction = .row,
            .align_items = .center,
            .gap = 8,
            .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 },
            .background = if (open.get()) t.muted else 0,
        },
        .children = util.dupElements(ctx.arena, &.{
            .{ .shape = .{
                .style = .{ .width = 14, .height = 14, .background = t.muted_foreground, .flex_shrink = 0 },
                .ops = chevron_ops,
                .fill = false,
                .stroke_width = 1.8,
                .view = 24,
            } },
            .{ .text = .{
                .style = .{ .color = t.foreground, .font_size = 14, .font_weight = .medium },
                .content = props.title,
            } },
        }) catch @panic("zui: out of memory while building the element tree"),
        .onclick = open.handler(boolToggle),
        .cursor = .hand,
    } };

    const border: element.Edges = if (props.last) .{} else .{ .bottom = 1 };
    return element.Element{ .rect = .{
        .style = .{
            .direction = .column,
            .border = border,
            .border_color = t.border,
        },
        .children = if (open.get())
            ctx.arena.dupe(element.Element, &.{ header, props.content }) catch
                @panic("zui: out of memory while building the element tree")
        else
            ctx.arena.dupe(element.Element, &.{header}) catch
                @panic("zui: out of memory while building the element tree"),
    } };
}

fn boolToggle(p: *bool) void {
    p.* = !p.*;
}
