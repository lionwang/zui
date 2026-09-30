//! Signals: reactive, copyable handles to shared state.
//!
//! A `Signal(T)` is a heap cell whose storage outlives any single frame. It is
//! the escape hatch for state shared between components: create it in a parent
//! component with `Context.useSignal`, pass it to children as props, and any
//! of them may read or write it.

const std = @import("std");
const element = @import("element.zig");

pub fn Signal(comptime T: type) type {
    return struct {
        ptr: *T,

        /// Create a signal that owns its own storage.
        pub fn create(allocator: std.mem.Allocator, initial: T) !@This() {
            const cell = try allocator.create(T);
            cell.* = initial;
            return .{ .ptr = cell };
        }

        pub fn destroy(self: @This(), allocator: std.mem.Allocator) void {
            allocator.destroy(self.ptr);
        }

        pub fn get(self: @This()) T {
            return self.ptr.*;
        }

        pub fn set(self: @This(), value: T) void {
            self.ptr.* = value;
        }

        /// Build an event handler that mutates this signal.
        pub fn handler(self: @This(), comptime f: fn (*T) void) element.Handler {
            const Wrapper = struct {
                fn run(p: *anyopaque) void {
                    f(@as(*T, @ptrCast(@alignCast(p))));
                }
            };
            return .{ .func = Wrapper.run, .data = self.ptr };
        }

        /// Build an event handler that sets this signal to a constant.
        pub fn setter(self: @This(), value: T) element.Handler {
            const Wrapper = struct {
                fn run(p: *anyopaque) void {
                    @as(*T, @ptrCast(@alignCast(p))).* = value;
                }
            };
            return .{ .func = Wrapper.run, .data = self.ptr };
        }
    };
}