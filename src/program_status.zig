//! Session-owned OSC 7501 records. Collection does not depend on whether
//! clients are attached or how their terminal chooses to display status.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const Report = ghostty.osc.Command.ProgramStatus.Report;
const Handler = @FieldType(ghostty.TerminalStream, "handler");

pub const Records = struct {
    pub const max_records = 256;

    // Oldest update first. Reports own their data; the parser's buffer is borrowed.
    items: std.ArrayList(Report) = .empty,

    pub fn deinit(self: *Records, alloc: std.mem.Allocator) void {
        self.clear(alloc, null);
        self.items.deinit(alloc);
    }

    pub fn get(self: *const Records, id: ?[]const u8) ?Report {
        for (self.items.items) |report| {
            if (sameId(report.readOption(.id), id)) return report;
        }
        return null;
    }

    pub fn apply(self: *Records, alloc: std.mem.Allocator, report: Report) !void {
        const id = report.readOption(.id);
        if (report.state == .clear) {
            self.clear(alloc, id);
            return;
        }

        // Allocate before replacing or evicting so allocation failure preserves
        // the previous records. libghostty validates every report before here.
        const data = try alloc.dupe(u8, report.data);
        errdefer alloc.free(data);
        try self.items.ensureTotalCapacity(alloc, @min(max_records, self.items.items.len + 1));

        for (self.items.items, 0..) |old, i| {
            if (sameId(old.readOption(.id), id)) {
                self.remove(alloc, i);
                break;
            }
        }
        if (self.items.items.len == max_records) self.remove(alloc, 0);
        self.items.appendAssumeCapacity(.{ .state = report.state, .data = data });
    }

    /// Shell prompts and attached-process exit expire active work. Idle,
    /// completed, and failed records remain until explicitly replaced/cleared.
    pub fn expireActive(self: *Records, alloc: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            switch (self.items.items[i].state) {
                .working, .blocked => self.remove(alloc, i),
                else => i += 1,
            }
        }
    }

    fn clear(self: *Records, alloc: std.mem.Allocator, id: ?[]const u8) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            const child = self.items.items[i].readOption(.id);
            const matches = if (id) |parent|
                if (child) |path| std.mem.eql(u8, parent, path) or
                    (std.mem.startsWith(u8, path, parent) and path.len > parent.len and path[parent.len] == '/') else false
            else
                true;
            if (matches) self.remove(alloc, i) else i += 1;
        }
    }

    fn remove(self: *Records, alloc: std.mem.Allocator, i: usize) void {
        alloc.free(self.items.orderedRemove(i).data);
    }

    fn sameId(a: ?[]const u8, b: ?[]const u8) bool {
        if (a) |value| return if (b) |other| std.mem.eql(u8, value, other) else false;
        return b == null;
    }
};

/// Must remain at a stable address while processing output, because effects
/// recover this owner through the embedded stream's handler.
pub const Stream = struct {
    vt: ghostty.TerminalStream,
    alloc: std.mem.Allocator,
    records: *Records,
    replies: *std.ArrayList(u8),
    /// Attached clients answer queries themselves. While detached, the daemon
    /// answers OSC 7501 so producers can begin reporting before the first attach.
    detached: bool = true,

    pub fn init(alloc: std.mem.Allocator, term: *ghostty.Terminal, records: *Records, replies: *std.ArrayList(u8)) Stream {
        var result: Stream = .{
            .vt = term.vtStream(),
            .alloc = alloc,
            .records = records,
            .replies = replies,
        };
        result.vt.handler.effects.program_status = &onReport;
        result.vt.handler.effects.semantic_prompt = &onPrompt;
        result.vt.handler.effects.write_pty = &onReply;
        return result;
    }

    pub fn deinit(self: *Stream) void {
        self.vt.deinit();
    }

    pub fn nextSlice(self: *Stream, data: []const u8) void {
        self.vt.nextSlice(data);
    }

    fn owner(handler: *Handler) *Stream {
        const vt: *ghostty.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("vt", vt);
    }

    fn onReport(handler: *Handler, report: Report) void {
        const self = owner(handler);
        self.records.apply(self.alloc, report) catch |err| {
            std.log.warn("failed to retain program status: {s}", .{@errorName(err)});
        };
    }

    fn onPrompt(handler: *Handler, event: ghostty.SemanticPrompt) void {
        const self = owner(handler);
        if (event.kind == .prompt_start) self.records.expireActive(self.alloc);
    }

    fn onReply(handler: *Handler, data: []const u8) void {
        const self = owner(handler);
        // Keep existing forwarding and device-query behavior. Only this new
        // protocol is answered here, and never in addition to an attached client.
        if (!self.detached or !std.mem.startsWith(u8, data, "\x1b]7501;?")) return;
        if (self.replies.items.len + data.len > 256 * 1024) return;
        self.replies.appendSlice(self.alloc, data) catch |err| {
            std.log.warn("failed to buffer program status reply: {s}", .{@errorName(err)});
        };
    }
};

const Fixture = struct {
    term: ghostty.Terminal = undefined,
    records: Records = .{},
    replies: std.ArrayList(u8) = .empty,
    stream: Stream = undefined,

    fn init(self: *Fixture) !void {
        self.term = try ghostty.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 80, .rows = 24 });
        self.stream = Stream.init(std.testing.allocator, &self.term, &self.records, &self.replies);
    }

    fn deinit(self: *Fixture) void {
        self.stream.deinit();
        self.records.deinit(std.testing.allocator);
        self.replies.deinit(std.testing.allocator);
        self.term.deinit(std.testing.allocator);
    }

    fn report(self: *Fixture, data: []const u8) void {
        self.stream.nextSlice("\x1b]7501;");
        self.stream.nextSlice(data);
        self.stream.nextSlice("\x1b\\");
    }
};

test "program status owns reports and replaces complete records" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();

    // Deliberately split escape sequences across reads, including the terminator.
    f.stream.nextSlice("\x1b]");
    f.stream.nextSlice("7501;state=blocked:app=claude-code:kind=permission:msg=QXBwcm92ZT8=\x1b");
    f.stream.nextSlice("\\");
    f.report("state=working:id=worker:progress=37");
    try std.testing.expectEqual(.blocked, f.records.get(null).?.state);
    try std.testing.expectEqualStrings("claude-code", f.records.get(null).?.readOption(.app).?);
    try std.testing.expectEqual(.permission, f.records.get(null).?.readOption(.kind).?);
    try std.testing.expectEqual(@as(u8, 37), f.records.get("worker").?.readOption(.progress).?);

    f.report("state=idle");
    const root = f.records.get(null).?;
    try std.testing.expectEqual(.idle, root.state);
    try std.testing.expect(root.readOption(.app) == null);
    try std.testing.expect(root.readOption(.kind) == null);
    try std.testing.expect(root.readOption(.msg) == null);
    try std.testing.expectEqual(@as(usize, 2), f.records.items.items.len);
}

test "program status clears descendants at path boundaries without requiring a parent" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.report("state=idle");
    f.report("state=blocked:id=build/test:kind=question");
    f.report("state=working:id=builder/test");
    f.report("state=clear:id=build");
    try std.testing.expect(f.records.get("build/test") == null);
    try std.testing.expect(f.records.get("builder/test") != null);
    try std.testing.expect(f.records.get(null) != null);
    f.report("state=clear");
    try std.testing.expectEqual(@as(usize, 0), f.records.items.items.len);
}

test "program status lifetimes distinguish prompts screens soft resets and full resets" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.report("state=working");
    f.report("state=blocked:id=blocked");
    f.report("state=done:id=done");
    f.report("state=error:id=error");
    f.report("state=idle:id=idle");
    f.stream.nextSlice("\x1b[?1049h\x1b[?1049l\x1b[!p");
    try std.testing.expectEqual(@as(usize, 5), f.records.items.items.len);
    f.stream.nextSlice("\x1b]133;A\x07");
    try std.testing.expect(f.records.get(null) == null);
    try std.testing.expect(f.records.get("blocked") == null);
    try std.testing.expectEqual(@as(usize, 3), f.records.items.items.len);

    f.report("state=working");
    f.records.expireActive(std.testing.allocator);
    try std.testing.expect(f.records.get(null) == null);
    try std.testing.expect(f.records.get("done") != null);
    f.stream.nextSlice("\x1bc");
    try std.testing.expectEqual(@as(usize, 0), f.records.items.items.len);
}

test "program status rejects malformed and oversized reports atomically" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.report("state=done:app=test");
    const invalid = [_][]const u8{
        "state=unknown",
        "state=blocked:id=bad//id",
        "state=blocked:msg=A",
        "state=blocked:msg=Cg==", // newline
        "state=blocked:title=wog=", // C1 control U+0088
        "state=blocked:abcdefghijklmnopq=x",
        "state=blocked:app=" ++ "a" ** 33,
        "state=blocked:msg=" ++ "YQ==" ** 684,
        "state=blocked:title=" ++ "YQ==" ** 65,
        "state=blocked:unknown=" ++ "x" ** 4096,
    };
    for (invalid) |data| {
        f.report(data);
        try std.testing.expectEqualStrings("test", f.records.get(null).?.readOption(.app).?);
        try std.testing.expectEqual(.done, f.records.get(null).?.state);
        try std.testing.expectEqual(@as(usize, 1), f.records.items.items.len);
    }
}

test "program status evicts the least recently updated record" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..Records.max_records) |i| {
        f.report(try std.fmt.bufPrint(&buf, "state=working:id=task-{d}", .{i}));
    }
    // Refreshing task-0 protects it; adding task-256 evicts task-1.
    f.report("state=blocked:id=task-0");
    f.report("state=working:id=task-256");
    try std.testing.expectEqual(@as(usize, Records.max_records), f.records.items.items.len);
    try std.testing.expect(f.records.get("task-0") != null);
    try std.testing.expect(f.records.get("task-1") == null);
    try std.testing.expect(f.records.get("task-256") != null);
}

test "program status supports detached producers and keeps collecting while attached" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.stream.nextSlice("\x1b]7501;?\x1b\\");
    try std.testing.expectEqualStrings("\x1b]7501;" ++ ghostty.osc.program_status.query_reply ++ "\x1b\\", f.replies.items);
    f.replies.clearRetainingCapacity();
    f.report("state=working");

    // One or more real clients own the query path. No duplicate daemon reply.
    f.stream.detached = false;
    f.stream.nextSlice("\x1b]7501;?\x07\x1b[c");
    try std.testing.expectEqual(@as(usize, 0), f.replies.items.len);
    f.report("state=blocked:kind=auth");
    try std.testing.expectEqual(.blocked, f.records.get(null).?.state);

    f.stream.detached = true;
    f.stream.nextSlice("\x1b]7501;?\x07");
    try std.testing.expectEqualStrings("\x1b]7501;" ++ ghostty.osc.program_status.query_reply ++ "\x07", f.replies.items);
    f.report("state=done");
    try std.testing.expectEqual(.done, f.records.get(null).?.state);
}

test "program status records with the same id are isolated between sessions" {
    var first: Fixture = .{};
    try first.init();
    defer first.deinit();
    var second: Fixture = .{};
    try second.init();
    defer second.deinit();
    first.report("state=blocked:id=worker");
    second.report("state=done:id=worker");
    first.report("state=clear");
    try std.testing.expectEqual(@as(usize, 0), first.records.items.items.len);
    try std.testing.expectEqual(.done, second.records.get("worker").?.state);
}

test "program status preserves existing records on allocation failure" {
    var records: Records = .{};
    defer records.deinit(std.testing.allocator);
    try records.apply(std.testing.allocator, .{ .state = .done, .data = "state=done:app=test" });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, records.apply(failing.allocator(), .{
        .state = .blocked,
        .data = "state=blocked",
    }));
    try std.testing.expectEqual(.done, records.get(null).?.state);
    try std.testing.expectEqualStrings("test", records.get(null).?.readOption(.app).?);
}

test "program status replies respect the PTY input buffer bound" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const reply_len = "\x1b]7501;".len + ghostty.osc.program_status.query_reply.len + 1;
    try f.replies.resize(std.testing.allocator, 256 * 1024 - reply_len);
    f.stream.nextSlice("\x1b]7501;?\x07");
    try std.testing.expectEqual(@as(usize, 256 * 1024), f.replies.items.len);
    f.stream.nextSlice("\x1b]7501;?\x07");
    try std.testing.expectEqual(@as(usize, 256 * 1024), f.replies.items.len);
}
