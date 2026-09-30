//! The render context passed to components.
//!
//! Hooks (Freya / React style) are the stateful backbone of the framework.
//! Because the whole element tree is rebuilt every frame, hook state cannot
//! live in the elements; it lives in the retained `node.Node` tree instead.
//! Each component invocation is given a Context pointing at its retained node,
//! and hooks are keyed by their call order within that component - exactly
//! like React's rules of hooks.

const std = @import("std");
const element = @import("element.zig");
const node = @import("node.zig");

pub const Context = struct {
    /// Per-frame arena used to build the element tree. Never use it for
    /// anything that must outlive the frame.
    arena: std.mem.Allocator,
    /// Retained node that owns this component's hook slots.
    node: *node.Node,
    /// Props boxed by `Context.component`, handed to the render function.
    props: ?*anyopaque = null,
    hook_index: usize = 0,

    /// Read / write stateful value owned by this component's node.
    ///
    /// ```zig
    /// var count = ctx.useState(i32, 0);
    /// count.set(count.get() + 1);
    /// ```
    pub fn useState(self: *Context, comptime T: type, initial: T) State(T) {
        const slot: *T = self.hookSlot(T, initial);
        return .{ .ptr = slot };
    }

    /// Alias of `useState` matching Freya's naming.
    pub fn useSignal(self: *Context, comptime T: type, initial: T) State(T) {
        return self.useState(T, initial);
    }

    /// Lazily compute a value once and cache it for the node's lifetime.
    pub fn useMemo(self: *Context, comptime T: type, comptime f: fn () T) T {
        const slot: *?T = self.hookSlot(?T, null);
        if (slot.* == null) {
            slot.* = f();
        }
        return slot.*.?;
    }

    /// Build a parameterized component element. Props are copied into the
    /// frame arena and expanded when the element tree is reconciled.
    pub fn component(
        self: *Context,
        comptime name: []const u8,
        props: anytype,
        comptime f: fn (@TypeOf(props)) element.Element,
    ) !element.Element {
        return element.componentProps(self.arena, name, props, f);
    }

    /// Acquire (or create) the typed slot for the current hook index.
    fn hookSlot(self: *Context, comptime T: type, initial: T) *T {
        const idx = self.hook_index;
        self.hook_index += 1;
        const n = self.node;
        const alloc = n.allocator;

        while (n.hooks.items.len <= idx) {
            const slot = alloc.create(T) catch @panic("zui: out of memory");
            slot.* = initial;
            n.hooks.append(alloc, .{
                .ptr = slot,
                .deinit = struct {
                    fn run(p: *anyopaque, a: std.mem.Allocator) void {
                        a.destroy(@as(*T, @ptrCast(@alignCast(p))));
                    }
                }.run,
            }) catch @panic("zui: out of memory");
        }
        return @as(*T, @ptrCast(@alignCast(n.hooks.items[idx].ptr)));
    }
};

/// Build a component element from a render function that takes no props.
///
/// ```zig
/// fn counter(ctx: *Context) Element {
///     var count = ctx.useState(i32, 0);
///     ...
/// }
/// return ctx.component("counter", counter);
/// ```
pub fn makeComponent(comptime name: []const u8, comptime f: fn (*Context) element.Element) element.Element {
    const Wrapper = struct {
        fn run(ctx: *anyopaque, _: *anyopaque) element.Element {
            return f(@as(*Context, @ptrCast(@alignCast(ctx))));
        }
    };
    return .{ .component = .{
        .name = name,
        .render = Wrapper.run,
        .props = null,
    } };
}

/// Build a component element with props. The props are boxed in `arena`,
/// which must stay alive until the tree has been reconciled.
pub fn makeComponentProps(
    arena: std.mem.Allocator,
    comptime name: []const u8,
    props: anytype,
    comptime f: fn (*Context, @TypeOf(props)) element.Element,
) !element.Element {
    const Props = @TypeOf(props);
    const Wrapper = struct {
        fn run(ctx: *anyopaque, p: *anyopaque) element.Element {
            return f(@as(*Context, @ptrCast(@alignCast(ctx))), @as(*Props, @ptrCast(@alignCast(p))).*);
        }
    };
    const boxed = try arena.create(Props);
    boxed.* = props;
    return .{ .component = .{
        .name = name,
        .render = Wrapper.run,
        .props = boxed,
    } };
}

/// `Context` method form of `makeComponent`.
pub fn component(self: *Context, comptime name: []const u8, comptime f: fn (*Context) element.Element) element.Element {
    _ = self;
    return makeComponent(name, f);
}

/// `Context` method form of `makeComponentProps`.
pub fn componentProps(
    self: *Context,
    comptime name: []const u8,
    props: anytype,
    comptime f: fn (*Context, @TypeOf(props)) element.Element,
) element.Element {
    return makeComponentProps(self.arena, name, props, f) catch .{ .none = {} };
}
/// A handle to a stateful value. The handle is cheap to copy; the underlying
/// storage is owned by the retained node and stays valid between frames.
pub fn State(comptime T: type) type {
    return struct {
        ptr: *T,

        pub fn get(self: @This()) T {
            return self.ptr.*;
        }

        pub fn set(self: @This(), value: T) void {
            self.ptr.* = value;
        }

        /// Build an event handler that mutates this state. Because Zig has no
        /// closures, the mutating function receives the state pointer:
        ///
        /// ```zig
        /// var count = ctx.useState(i32, 0);
        /// .onclick = count.handler(struct {
        ///     fn inc(p: *i32) void { p.* += 1; }
        /// }.inc)
        /// ```
        pub fn handler(self: @This(), comptime f: fn (*T) void) element.Handler {
            const Wrapper = struct {
                fn run(p: *anyopaque) void {
                    f(@as(*T, @ptrCast(@alignCast(p))));
                }
            };
            return .{ .func = Wrapper.run, .data = self.ptr };
        }
    };
}