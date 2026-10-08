//! The chat data model: seeded sessions, the append-only store, and
//! the Win32 clock helper backing the timestamps.

const std = @import("std");

const TimeBuf = struct {
    buf: [16]u8 = undefined,
    len: u4 = 0,

    fn set(self: *TimeBuf, text: []const u8) void {
        const n = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = @intCast(n);
    }

    /// The slice points into the buffer itself, so `self` must be borrowed:
    /// a by-value `self` would return a slice into a stack copy that dies
    /// on return, and callers would later read freed bytes - the exact
    /// "garbled time" symptom (length intact, bytes zeroed or garbage).
    pub fn view(self: *const TimeBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

/// One row of a conversation: either a time divider or a message.
pub const Item = union(enum) {
    time: TimeBuf,
    msg: struct { mine: bool, text: []const u8 },
};

pub const Session = struct {
    name: []const u8,
    color: u32,
    is_helper: bool = false,
    replies: []const []const u8,
    last: [96]u8 = undefined,
    last_len: u8 = 0,
    time: TimeBuf = .{},
    unread: u32 = 0,
};

pub const ChatSeed = struct { time: []const u8, mine: bool, text: []const u8 };
pub const SessionSeed = struct {
    name: []const u8,
    color: u32,
    is_helper: bool = false,
    last: []const u8,
    time: []const u8,
    unread: u32 = 0,
    replies: []const []const u8,
    chat: []const ChatSeed,
};

const sessions_seed = [_]SessionSeed{
    .{
        .name = "文件传输助手",
        .color = 0xFF4C8DDB,
        .is_helper = true,
        .last = "网页版微信已上线，快来试试",
        .time = "10:12",
        .replies = &.{ "文件已备份到电脑", "收到，已为你传输完成", "点击这里查看历史文件" },
        .chat = &.{
            .{ .time = "昨天 21:18", .mine = false, .text = "网页版微信已上线，扫码即可在电脑上继续聊天。" },
            .{ .time = "", .mine = true, .text = "好的，我现在就试试" },
            .{ .time = "10:12", .mine = false, .text = "发给我的聊天记录和文件在这里都能找到。" },
        },
    },
    .{
        .name = "张伟",
        .color = 0xFF7CB342,
        .last = "好的，到了告诉我一声",
        .time = "09:41",
        .unread = 2,
        .replies = &.{ "嗯嗯，知道了", "好的，没问题", "哈哈，是啊", "我也这么觉得" },
        .chat = &.{
            .{ .time = "昨天 22:14", .mine = false, .text = "在吗？" },
            .{ .time = "", .mine = true, .text = "在的，怎么了" },
            .{ .time = "", .mine = false, .text = "周末一起去爬山吗？我看天气预报还不错，温度大概 15 到 22 度，正好适合户外活动。" },
            .{ .time = "", .mine = true, .text = "可以啊，去哪座山？香山还是百望山？" },
            .{ .time = "", .mine = false, .text = "香山吧，坐地铁过去很方便，早上九点在门口集合？" },
            .{ .time = "", .mine = true, .text = "行，那就周六早上九点，不见不散" },
            .{ .time = "今天 09:12", .mine = false, .text = "早上好，今天降温了，记得多穿点衣服" },
            .{ .time = "", .mine = true, .text = "收到，我已经出门了" },
            .{ .time = "", .mine = false, .text = "好的，到了告诉我一声" },
            .{ .time = "", .mine = false, .text = "对了，上次说的那个登山路线我发你了一份，你回头看看" },
            .{ .time = "", .mine = true, .text = "看到了，整体没问题，就是下山的路有点陡" },
            .{ .time = "", .mine = false, .text = "嗯，所以咱们慢点走，安全第一" },
            .{ .time = "", .mine = true, .text = "同意，到时候听你的安排" },
        },
    },
    .{
        .name = "产品讨论组",
        .color = 0xFF5B8DEF,
        .last = "陈晨: 新版本已经上测试环境了",
        .time = "09:26",
        .unread = 9,
        .replies = &.{ "收到，我再看一下", "这个想法不错", "稍等，我确认一下需求" },
        .chat = &.{
            .{ .time = "昨天 18:02", .mine = false, .text = "大家看下最新的原型，首页改了三版，主要想听听意见" },
            .{ .time = "", .mine = false, .text = "陈晨: 我觉得列表页的间距还可以再紧凑一点" },
            .{ .time = "", .mine = true, .text = "同意，另外顶部的标签能不能默认选中最近使用的" },
            .{ .time = "", .mine = false, .text = "设计稿今晚更新，明早同步给大家" },
            .{ .time = "今天 09:26", .mine = false, .text = "陈晨: 新版本已经上测试环境了" },
        },
    },
    .{
        .name = "李娜",
        .color = 0xFFEC6C5C,
        .last = "🤣",
        .time = "08:47",
        .replies = &.{ "哈哈哈", "好的", "晚点联系", "嗯嗯" },
        .chat = &.{
            .{ .time = "星期二 20:31", .mine = false, .text = "你昨天说的那家餐厅真不错！" },
            .{ .time = "", .mine = true, .text = "是吧，下次再约" },
            .{ .time = "", .mine = false, .text = "🤣" },
        },
    },
    .{
        .name = "妈妈",
        .color = 0xFFD9A441,
        .last = "记多穿点衣服",
        .time = "昨天",
        .replies = &.{ "知道了，妈", "好的，我这周就回去", "嗯，最近挺好的" },
        .chat = &.{
            .{ .time = "昨天 19:05", .mine = false, .text = "最近降温了，多穿点衣服" },
            .{ .time = "", .mine = true, .text = "知道了妈，我穿了羽绒服" },
            .{ .time = "", .mine = false, .text = "记多穿点衣服" },
        },
    },
    .{
        .name = "同学群",
        .color = 0xFF8D8FE0,
        .last = "王芳: 聚会时间定了吗",
        .time = "昨天",
        .unread = 5,
        .replies = &.{ "我先看看时间", "收到", "哈哈哈那时候真好" },
        .chat = &.{
            .{ .time = "11/20 21:30", .mine = false, .text = "王芳: 聚会时间定了吗" },
            .{ .time = "", .mine = true, .text = "这周末应该可以" },
            .{ .time = "", .mine = false, .text = "王芳: 那就定周六晚上？" },
        },
    },
    .{
        .name = "王芳",
        .color = 0xFF42B0A5,
        .last = "文档已经发你邮箱了",
        .time = "星期三",
        .replies = &.{ "好的，收到", "我查一下", "感谢" },
        .chat = &.{
            .{ .time = "星期三 15:20", .mine = true, .text = "上次说的文档能再发我一份吗" },
            .{ .time = "", .mine = false, .text = "文档已经发你邮箱了" },
        },
    },
    .{
        .name = "公司大群",
        .color = 0xFFE5885E,
        .last = "行政: 下周一下午团建",
        .time = "星期一",
        .unread = 18,
        .replies = &.{ "收到", "我会准时到的", "期待" },
        .chat = &.{
            .{ .time = "星期一 10:00", .mine = false, .text = "行政: 下周一下午团建，请大家安排好时间" },
        },
    },
    .{
        .name = "订阅号",
        .color = 0xFF9E9E9E,
        .last = "科技早报: 今日要点",
        .time = "11/18",
        .replies = &.{},
        .chat = &.{
            .{ .time = "11/18 08:00", .mine = false, .text = "科技早报: 今日要点" },
        },
    },
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    sessions: []Session = &.{},
    msgs: []std.ArrayList(Item) = &.{},

    pub fn make(alloc: std.mem.Allocator) !Store {
        var store = Store{ .alloc = alloc };
        store.sessions = try alloc.alloc(Session, sessions_seed.len);
        store.msgs = try alloc.alloc(std.ArrayList(Item), sessions_seed.len);
        for (sessions_seed, 0..) |seed, i| {
            store.sessions[i] = .{
                .name = seed.name,
                .color = seed.color,
                .is_helper = seed.is_helper,
                .replies = seed.replies,
                .unread = seed.unread,
            };
            const s = &store.sessions[i];
            s.last_len = @intCast(@min(seed.last.len, s.last.len));
            @memcpy(s.last[0..s.last_len], seed.last[0..s.last_len]);
            s.time.set(seed.time);
            store.msgs[i] = .empty;
            for (seed.chat) |msg| {
                // A chat entry may carry both a time and text: the time is a
                // separator pill shown above the message, exactly like the
                // real client - so emit both items instead of dropping the
                // message (an entry with time but no text is a bare pill).
                if (msg.time.len > 0) {
                    var pill: Item = .{ .time = .{} };
                    pill.time.set(msg.time);
                    try store.msgs[i].append(alloc, pill);
                }
                if (msg.text.len > 0) {
                    try store.msgs[i].append(alloc, .{ .msg = .{ .mine = msg.mine, .text = msg.text } });
                }
            }
        }
        return store;
    }

    /// Append a message; the text is copied so the caller may reuse the
    /// buffer it came from (the input box, which is cleared right after).
    pub fn append(self: *Store, session: usize, text: []const u8, mine: bool) !void {
        const dup = try self.alloc.dupe(u8, text);
        try self.msgs[session].append(self.alloc, .{ .msg = .{ .mine = mine, .text = dup } });
    }

    pub fn setPreview(self: *Store, session: usize, text: []const u8) void {
        const s = &self.sessions[session];
        var n = @min(text.len, s.last.len);
        if (text.len > n) {
            // Keep the cut on a code point boundary.
            while (n > 0 and (text[n - 1] & 0xC0) == 0x80) n -= 1;
            if (n > 0 and (text[n - 1] & 0x80) != 0) n -= 1;
        }
        @memcpy(s.last[0..n], text[0..n]);
        s.last_len = @intCast(n);
        s.time.set(now());
    }
};

/// Current local time as "HH:MM" (in a static buffer, valid until the next
/// call - it is only used to fill the caller's own buffer).
pub fn now() []const u8 {
    const Static = struct {
        var buf: [16]u8 = undefined;

        fn fetch() []const u8 {
            const st = sys.getLocalTime();
            const s = std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{ st.hour, st.minute }) catch return "";
            return buf[0..s.len];
        }
    };
    return Static.fetch();
}

pub const sys = struct {
    const SystemTime = extern struct {
        year: u16,
        month: u16,
        day_of_week: u16,
        day: u16,
        hour: u16,
        minute: u16,
        second: u16,
        milliseconds: u16,
    };

    extern "kernel32" fn GetLocalTime(st: *SystemTime) callconv(.winapi) void;
    extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

    fn getLocalTime() SystemTime {
        var st: SystemTime = undefined;
        GetLocalTime(&st);
        return st;
    }

    pub fn sleep(milliseconds: u32) void {
        Sleep(milliseconds);
    }
};

test "TimeBuf keeps the bytes it was given" {
    var t: TimeBuf = .{};
    t.set("10:12");
    // The slice must alias the buffer itself: a `self: TimeBuf` signature
    // returned a slice into a stack copy that died on return, so reading
    // `v` afterwards picked up freed bytes (garbled times in the window).
    const v = t.view();
    try std.testing.expectEqualStrings("10:12", v);
}

test "Store.make seeds session times" {
    var store = try Store.make(std.testing.allocator);
    defer {
        for (store.msgs) |*m| m.deinit(std.testing.allocator);
        store.alloc.free(store.sessions);
        store.alloc.free(store.msgs);
    }
    try std.testing.expectEqualStrings("10:12", store.sessions[0].time.view());
    const first = store.msgs[0].items[0];
    try std.testing.expect(first == .time);
    try std.testing.expectEqualStrings("昨天 21:18", first.time.view());
}
