//! Entry point for the WeChat-style chat example.
//!
//!   zig build wechat            run the window (Escape to quit)
//!   zig build wechat -- check   drive it headless and write
//!                               screenshot_wechat.png of the result

const std = @import("std");

const app_mod = @import("app.zig");
const check = @import("check.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, std.heap.page_allocator) catch return;
    defer args.deinit();
    _ = args.next(); // the program path
    var want_check = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "check")) want_check = true;
    }

    if (want_check) {
        try check.run();
    } else {
        try app_mod.run();
    }
}
