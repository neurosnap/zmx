//! Test dispatch, ordering, replies, cleanup, and failure handling for any capability.
const std = @import("std");
const api = @import("zmx").capabilities;
const runtime = @import("capability-runtime");
const ghostty = @import("ghostty-vt");
const fixtures = @import("capabilities/session.zig");
const Session = fixtures.Session;
const repeat = fixtures.repeat;
const alloc = std.testing.allocator;

comptime {
    _ = @import("program_status/test.zig");
    _ = @import("working_directory/test.zig");
}

test "libzmx exposes the capability authoring API without daemon runtime controls" {
    const declarations = std.meta.declarations(api);
    try std.testing.expectEqual(@as(usize, 4), declarations.len);

    inline for (.{ "Terminal", "Event", "Reply", "Definition" }) |name| {
        try std.testing.expect(@hasDecl(api, name));
    }
}

/// 'lifecycle' logs capability creation, observation, and destruction for the active test.
var lifecycle: ?*std.ArrayList(u8) = null;

/// Return a test capability type that logs its calls and can fail during startup or restore.
/// Different letter values produce distinct capability types with independent state.
fn Probe(comptime letter: u8, comptime fail_init: bool, comptime fail_restore: bool) type {
    return struct {
        count: usize = 0,

        fn log(byte: u8) void {
            if (lifecycle) |list| list.append(alloc, byte) catch @panic("test allocation failed");
        }

        pub fn init(_: std.mem.Allocator) !@This() {
            if (fail_init) {
                return error.TestInitFailed;
            }

            log(letter);
            return .{};
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            log(std.ascii.toLower(letter));
        }

        pub fn observe(self: *@This(), _: std.mem.Allocator, event: api.Event, reply: *api.Reply) void {
            switch (event) {
                .action => |action| switch (action) {
                    .bell => {
                        self.count += 1;
                        log(letter);
                        _ = reply.send(&.{letter});
                    },
                    else => {},
                },
                else => {},
            }
        }

        pub fn restore(self: *@This(), _: *const api.Terminal, writer: *std.Io.Writer) !void {
            try writer.print("{c}{d}", .{ letter, self.count });
            if (fail_restore) {
                return error.TestRestoreFailed;
            }
        }
    };
}

const first = api.Definition.of("first", Probe('A', false, false));
const second = api.Definition.of("second", Probe('B', false, false));
const bad_restore = api.Definition.of("bad-restore", Probe('X', false, true));

test "capabilities dispatch and restore in configured order with independent session instances" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(alloc);

    lifecycle = &log;
    defer lifecycle = null;

    {
        const definitions = [_]api.Definition{ second, first };
        var one: Session = .{};
        try one.init(&definitions);
        defer one.deinit();

        var two: Session = .{};
        try two.init(&definitions);
        defer two.deinit();

        one.stream.nextSlice("\x07\x07");
        two.stream.nextSlice("\x07");
        const one_snapshot = try one.snapshot();
        defer alloc.free(one_snapshot);

        const two_snapshot = try two.snapshot();
        defer alloc.free(two_snapshot);

        try std.testing.expectEqualStrings("B2A2", one_snapshot);
        try std.testing.expectEqualStrings("B1A1", two_snapshot);
        try std.testing.expectEqualStrings("BB", one.input.items);
        try std.testing.expectEqualStrings("B", two.input.items);
    }

    try std.testing.expectEqualStrings("BABABABABAabab", log.items);
}

test "capabilities clean up earlier instances if a later initialization fails" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(alloc);

    lifecycle = &log;
    defer lifecycle = null;

    const bad = api.Definition.of("bad-init", Probe('X', true, false));
    try std.testing.expectError(error.TestInitFailed, runtime.Session.init(alloc, &.{ first, second, bad }));
    try std.testing.expectEqualStrings("ABba", log.items);
    try std.testing.checkAllAllocationFailures(alloc, initTwoCapabilities, .{});
}

fn initTwoCapabilities(allocator: std.mem.Allocator) !void {
    var session = try runtime.Session.init(allocator, &.{ first, second });
    defer session.deinit();
}

test "empty capability configuration preserves the normal terminal and emits nothing" {
    var session: Session = .{};
    try session.init(&.{});
    defer session.deinit();

    var expected_term = try ghostty.Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer expected_term.deinit(alloc);

    var expected_stream = expected_term.vtStream();
    defer expected_stream.deinit();

    const bytes = "hello\x1b[2D!!\x1b]7;file://localhost/tmp\x07\x1b]7777;example\x07";
    session.stream.nextSlice(bytes);
    expected_stream.nextSlice(bytes);
    const actual = try session.term.plainString(alloc);
    defer alloc.free(actual);

    const expected = try expected_term.plainString(alloc);
    defer alloc.free(expected);

    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqualStrings(expected_term.getPwd().?, session.term.getPwd().?);
    try std.testing.expectEqualStrings("", session.input.items);
    const snapshot = try session.snapshot();
    defer alloc.free(snapshot);

    try std.testing.expectEqualStrings("", snapshot);
    try std.testing.expect(session.stream.continuation == null);
}

test "capabilities discard a partial failed snapshot and still restore later capabilities and continuation" {
    var session: Session = .{};
    try session.init(&.{ first, bad_restore, second });
    defer session.deinit();

    session.stream.nextSlice("\x07\x1b]0;unfinished");
    const snapshot = try session.snapshot();
    defer alloc.free(snapshot);

    try std.testing.expectEqualStrings("A1B1\x1b]0;unfinished", snapshot);
}

test "capabilities keep restoring after an output queue rejects one snapshot" {
    const RejectFirst = struct {
        calls: usize = 0,
        buffer: std.Io.Writer.Allocating = .init(alloc),

        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls == 1) {
                return error.OutOfMemory;
            }

            try self.buffer.writer.writeAll(bytes);
        }
    };

    var session: Session = .{};
    try session.init(&.{ first, second });
    defer session.deinit();

    session.stream.nextSlice("\x1b[");
    var output: RejectFirst = .{};
    defer output.buffer.deinit();

    runtime.restore(&session.stream, .{ .context = &output, .write = RejectFirst.write });
    try std.testing.expectEqual(@as(usize, 3), output.calls);
    try std.testing.expectEqualStrings("B0\x1b[", output.buffer.writer.buffered());
}

test "capability query replies have one owner and follow current terminal attachment" {
    var session: Session = .{};
    try session.init(&.{ first, second });
    defer session.deinit();

    session.attached = true;
    session.stream.nextSlice("\x07");
    try std.testing.expectEqualStrings("", session.input.items);
    session.attached = false;
    session.stream.nextSlice("\x07");
    try std.testing.expectEqualStrings("A", session.input.items);
    const snapshot = try session.snapshot();
    defer alloc.free(snapshot);

    try std.testing.expectEqualStrings("A2B2", snapshot);
}

const Unknown = struct {
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(_: std.mem.Allocator) !Unknown {
        return .{};
    }

    pub fn deinit(self: *Unknown, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    pub fn observe(self: *Unknown, allocator: std.mem.Allocator, event: api.Event, _: *api.Reply) void {
        switch (event) {
            .action => |action| switch (action) {
                .osc_unknown => |osc| self.bytes.appendSlice(allocator, osc.content) catch @panic("test allocation failed"),
                else => {},
            },
            else => {},
        }
    }

    pub fn restore(self: *Unknown, _: *const api.Terminal, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.bytes.items);
    }
};

test "a capability can observe an unknown OSC protocol without changing the host" {
    var definition = api.Definition.of("unknown", Unknown);
    definition.osc_unknown_max_bytes = 32;
    var session: Session = .{};
    try session.init(&.{definition});
    defer session.deinit();

    session.stream.nextSlice("\x1b]7777;hello\x07");
    const snapshot = try session.snapshot();
    defer alloc.free(snapshot);

    try std.testing.expectEqualStrings("7777;hello", snapshot);
}

test "capabilities use the largest requested parser limits regardless of configuration order" {
    var large = api.Definition.of("large", Unknown);
    large.continuation_max_bytes = 128;
    large.osc_unknown_max_bytes = 64;
    var small = api.Definition.of("small", Unknown);
    small.continuation_max_bytes = 16;
    small.osc_unknown_max_bytes = 8;
    for ([_][2]api.Definition{ .{ large, small }, .{ small, large } }) |definitions| {
        var session: Session = .{};
        try session.init(&definitions);
        defer session.deinit();

        const pending = "\x1b]7777;" ++ repeat("x", 40);
        session.stream.nextSlice(pending);
        const snapshot = try session.snapshot();
        defer alloc.free(snapshot);

        try std.testing.expectEqualStrings(pending, snapshot);
        session.stream.nextSlice("\x07");
        const complete = try session.snapshot();
        defer alloc.free(complete);

        try std.testing.expectEqualStrings("7777;" ++ repeat("x", 40) ++ "7777;" ++ repeat("x", 40), complete);
    }
}

const Truncation = struct {
    received_truncated: bool = false,

    pub fn init(_: std.mem.Allocator) !Truncation {
        return .{};
    }

    pub fn deinit(_: *Truncation, _: std.mem.Allocator) void {}

    pub fn observe(self: *Truncation, _: std.mem.Allocator, event: api.Event, _: *api.Reply) void {
        switch (event) {
            .action => |action| switch (action) {
                .osc_unknown => |osc| self.received_truncated = osc.truncated,
                else => {},
            },
            else => {},
        }
    }

    pub fn restore(self: *Truncation, _: *const api.Terminal, writer: *std.Io.Writer) !void {
        try writer.writeAll(if (self.received_truncated) "truncated" else "complete");
    }
};

test "unknown OSC capabilities can distinguish truncated data from a complete message" {
    var definition = api.Definition.of("truncation", Truncation);
    definition.osc_unknown_max_bytes = 8;
    var session: Session = .{};
    try session.init(&.{definition});
    defer session.deinit();

    session.stream.nextSlice("\x1b]7777;too-long-for-the-limit\x07");
    const snapshot = try session.snapshot();
    defer alloc.free(snapshot);

    try std.testing.expectEqualStrings("truncated", snapshot);
    session.stream.nextSlice("\x1b]7777;ok\x07");
    const recovered = try session.snapshot();
    defer alloc.free(recovered);

    try std.testing.expectEqualStrings("complete", recovered);
}

test "duplicate definitions fail before any capability starts" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(alloc);

    lifecycle = &log;
    defer lifecycle = null;

    try std.testing.expectError(error.DuplicateCapability, runtime.Session.init(alloc, &.{ first, second, first }));
    try std.testing.expectEqualStrings("", log.items);
}
