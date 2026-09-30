//! A reactive counter, mirroring Freya's introductory counter example.
//!
//! State lives in a hook owned by the component's retained node; clicking a
//! button mutates it and the tree is re-rendered on the next frame.

const std = @import("std");
const zui = @import("zui");
const ui = zui.widgets;
const Context = zui.Context;
const Element = zui.Element;

pub const Counter = struct {
    /// This app takes no props.
    pub const Props = void;

    pub fn render(ctx: *Context, props: Props) Element {
        _ = props;

        var count = ctx.useState(i32, 0);

        return ui.column(ctx, .{
            .style = .{
                .padding = .all(24),
                .gap = 16,
                .background = 0xFF1E1E2E,
                .align_items = .center,
                .justify_content = .center,
                .flex_grow = 1,
            },
            .children = &.{
                ui.text(.{
                    .color = 0xFF89B4FA,
                    .font_size = 18,
                    .font_weight = .semibold,
                }, "zui counter"),
                ui.text(.{
                    .color = 0xFFEAEAEA,
                    .font_size = 56,
                    .font_weight = .bold,
                    .line_height = 1.1,
                }, std.fmt.allocPrint(ctx.arena, "{d}", .{count.get()}) catch "<err>"),
                ui.row(ctx, .{
                    .style = .{ .gap = 12 },
                    .children = &.{
                        ui.button(ctx, .{
                            .label = "- 1",
                            .style = .{ .background = 0xFF6C7086 },
                            .onclick = count.handler(struct {
                                fn dec(p: *i32) void {
                                    p.* -= 1;
                                }
                            }.dec),
                        }),
                        ui.button(ctx, .{
                            .label = "+ 1",
                            .style = .{ .background = 0xFF89B4FA },
                            .onclick = count.handler(struct {
                                fn inc(p: *i32) void {
                                    p.* += 1;
                                }
                            }.inc),
                        }),
                    },
                }),
                ui.text(.{
                    .color = 0xFF6C7086,
                    .font_size = 13,
                }, "press Escape to quit"),
            },
        });
    }
};

pub fn main() !void {
    try zui.launch(Counter, .{});
}