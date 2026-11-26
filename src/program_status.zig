const std = @import("std");
const ghostty = @import("ghostty-vt");

const ProgramStatus = @This();
const Report = ghostty.osc.Command.ProgramStatus.Report;
const max_records = 64;

const Record = struct {
    report: Report,
    id: []const u8,
};

records: std.ArrayList(Record) = .empty,

pub fn deinit(self: *ProgramStatus, alloc: std.mem.Allocator) void {
    for (self.records.items) |record| alloc.free(record.report.data);
    self.records.deinit(alloc);
}

fn remove(self: *ProgramStatus, alloc: std.mem.Allocator, index: usize) void {
    alloc.free(self.records.orderedRemove(index).report.data);
}

fn isDescendant(id: []const u8, parent: []const u8) bool {
    if (parent.len == 0) return true;
    return id.len > parent.len and id[parent.len] == '/' and std.mem.startsWith(u8, id, parent);
}

pub fn update(self: *ProgramStatus, alloc: std.mem.Allocator, report: Report) !void {
    const id = report.readOption(.id) orelse "";
    var i = self.records.items.len;
    while (i > 0) {
        i -= 1;
        const saved_id = self.records.items[i].id;
        if (std.mem.eql(u8, saved_id, id)) {
            self.remove(alloc, i);
            if (report.state != .clear) break;
        } else if (report.state == .clear and isDescendant(saved_id, id)) {
            self.remove(alloc, i);
        }
    }
    if (report.state == .clear) return;

    const saved: Report = .{ .state = report.state, .data = try alloc.dupe(u8, report.data) };
    errdefer alloc.free(saved.data);
    if (self.records.items.len == max_records) self.remove(alloc, 0);
    try self.records.append(alloc, .{ .report = saved, .id = saved.readOption(.id) orelse "" });
}

pub fn prompt(self: *ProgramStatus, alloc: std.mem.Allocator) void {
    var i = self.records.items.len;
    while (i > 0) {
        i -= 1;
        switch (self.records.items[i].report.state) {
            .working, .blocked => self.remove(alloc, i),
            else => {},
        }
    }
}

pub fn write(self: *const ProgramStatus, writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1b]7501;state=clear\x1b\\");
    for (self.records.items) |record| {
        try writer.print("\x1b]7501;state={t}", .{record.report.state});
        inline for (.{ .id, .kind, .progress, .app, .title, .msg }) |key| {
            if (record.report.readOption(key)) |value| {
                const format = switch (key) {
                    .kind => "{t}",
                    .progress => "{d}",
                    else => "{s}",
                };
                try writer.print(":" ++ @tagName(key) ++ "=" ++ format, .{value});
            }
        }
        try writer.writeAll("\x1b\\");
    }
}

pub const Stream = struct {
    stream: ghostty.TerminalStream,
    status: ?ProgramStatus = null,
    replies: ?Replies = null,

    const Handler = ghostty.TerminalStream.Handler;
    const Replies = struct { queue: *std.ArrayList(u8), limit: usize };

    pub fn init(term: *ghostty.Terminal) Stream {
        var handler = term.vtHandler();
        handler.effects.program_status = onReport;
        return .{ .stream = .init(.{
            .allocator = term.gpa(),
            .handler = handler,
            .continuation_max_bytes = ghostty.osc.program_status.max_sequence_bytes,
        }) };
    }

    pub fn deinit(self: *Stream) void {
        if (self.status) |*status| status.deinit(self.stream.handler.terminal.gpa());
        self.stream.deinit();
    }

    fn owner(handler: *Handler) *Stream {
        const stream: *ghostty.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream);
    }

    fn onReport(handler: *Handler, report: Report) void {
        const self = owner(handler);
        if (self.status == null) {
            if (report.state == .clear) return;
            self.status = .{};
            handler.effects.semantic_prompt = onPrompt;
        }
        self.status.?.update(handler.terminal.gpa(), report) catch |err|
            std.log.warn("failed to retain program status err={s}", .{@errorName(err)});
    }

    fn onPrompt(handler: *Handler, event: Handler.SemanticPrompt) void {
        if (event.kind == .prompt_start and event.prompt_kind == .primary)
            owner(handler).status.?.prompt(handler.terminal.gpa());
    }

    fn onReply(handler: *Handler, data: []const u8) void {
        const reply = "\x1b]7501;" ++ ghostty.osc.program_status.query_reply;
        if (!std.mem.eql(u8, data, reply ++ "\x07") and
            !std.mem.eql(u8, data, reply ++ "\x1b\\")) return;
        const dest = owner(handler).replies.?;
        if (dest.queue.items.len + data.len <= dest.limit)
            dest.queue.appendSlice(handler.terminal.gpa(), data) catch {};
    }

    pub fn feed(self: *Stream, data: []const u8, replies: ?Replies) void {
        self.replies = replies;
        self.stream.handler.effects.write_pty = if (replies != null) onReply else null;
        defer self.stream.handler.effects.write_pty = null;
        defer self.replies = null;
        self.stream.nextSlice(data);
    }

    pub fn writeReplay(self: *Stream, writer: *std.Io.Writer) !void {
        if (self.status) |*status| try status.write(writer);
        if (self.stream.ground()) return;
        const prefix = "\x1b]7501;";
        var buf: [ghostty.osc.program_status.max_sequence_bytes + 1]u8 = undefined;
        var pending: std.Io.Writer = .fixed(&buf);
        self.stream.writeContinuation(&pending) catch return;
        const bytes = pending.buffered();
        if (std.mem.startsWith(u8, prefix, bytes)) return writer.writeAll(bytes);
        if (!std.mem.startsWith(u8, bytes, prefix)) return;

        for (buf[prefix.len..bytes.len]) |*c| {
            if (!std.ascii.isPrint(c.*)) c.* = '!';
        }
        try writer.writeAll(bytes);
    }
};

test "replay restores the current records across a split report" {
    const alloc = std.testing.allocator;
    var term = try ghostty.Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);
    var stream = Stream.init(&term);
    defer stream.deinit();
    stream.feed("\x1b]7501;state=working:id=build:progress=50\x07", null);
    stream.feed("\x1b]7501;state=blocked:id=build\x07", null);
    stream.feed("\x1b]7501;state=do", null);

    var buf: [256]u8 = undefined;
    var replay: std.Io.Writer = .fixed(&buf);
    try stream.writeReplay(&replay);

    var client_term = try ghostty.Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer client_term.deinit(alloc);
    var client = Stream.init(&client_term);
    defer client.deinit();
    client.feed(replay.buffered(), null);
    client.feed("ne:id=test\x07", null);

    const records = (client.status orelse return error.TestExpectedEqual).records.items;
    try std.testing.expectEqual(2, records.len);
    try std.testing.expectEqualStrings("build", records[0].id);
    try std.testing.expectEqual(.blocked, records[0].report.state);
    try std.testing.expect(records[0].report.readOption(.progress) == null);
    try std.testing.expectEqualStrings("test", records[1].id);
    try std.testing.expectEqual(.done, records[1].report.state);
}

test "clear removes a subtree and a primary prompt expires active tasks" {
    const alloc = std.testing.allocator;
    var term = try ghostty.Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);
    var stream = Stream.init(&term);
    defer stream.deinit();
    stream.feed("\x1b]7501;state=working:id=build\x07", null);
    stream.feed("\x1b]7501;state=done:id=build/test\x07", null);
    stream.feed("\x1b]7501;state=blocked:id=builder\x07", null);
    stream.feed("\x1b]7501;state=done:id=deploy\x07", null);
    stream.feed("\x1b]7501;state=clear:id=build\x07", null);

    const records = (stream.status orelse return error.TestExpectedEqual).records.items;
    try std.testing.expectEqual(2, records.len);
    try std.testing.expectEqualStrings("builder", records[0].id);
    stream.feed("\x1b]133;A\x07", null);
    try std.testing.expectEqual(1, stream.status.?.records.items.len);
    try std.testing.expectEqualStrings("deploy", stream.status.?.records.items[0].id);
}
