//! Exercise Program Status (OSC 7501) through the same capability API the daemon uses.
const std = @import("std");
const api = @import("zmx").capabilities;
const ghostty = @import("ghostty-vt");
const fixtures = @import("../capabilities/session.zig");
const Session = fixtures.Session;
const repeat = fixtures.repeat;
const alloc = std.testing.allocator;
const osc_definitions = [_]api.Definition{@import("zmx").capability_definitions.program_status};
const clear = "\x1b]7501;state=clear\x1b\\";

fn sendReport(session: *Session, body: []const u8) void {
    session.stream.nextSlice("\x1b]7501;");
    session.stream.nextSlice(body);
    session.stream.nextSlice("\x1b\\");
}

test "Program Status capability restores current root and nested tasks and replaces whole records" {
    var session: Session = .{};
    try session.init(&osc_definitions);
    defer session.deinit();

    sendReport(&session, "state=working:app=agent");
    sendReport(&session, "state=blocked:id=build/test:kind=permission");
    sendReport(&session, "state=working:id=builder");
    sendReport(&session, "state=idle");

    // Check the nested task before clearing it, so an earlier loss cannot make
    // the subtree-clear assertion below pass without removing anything.
    const before_clear = try session.snapshot();
    defer alloc.free(before_clear);

    try std.testing.expectEqualStrings(clear ++
        "\x1b]7501;state=blocked:id=build/test:kind=permission\x1b\\" ++
        "\x1b]7501;state=working:id=builder\x1b\\\x1b]7501;state=idle\x1b\\", before_clear);

    sendReport(&session, "state=clear:id=build");
    const snapshot = try session.snapshot();
    defer alloc.free(snapshot);

    try std.testing.expectEqualStrings(clear ++ "\x1b]7501;state=working:id=builder\x1b\\\x1b]7501;state=idle\x1b\\", snapshot);
    sendReport(&session, "state=clear");
    const empty = try session.snapshot();
    defer alloc.free(empty);

    try std.testing.expectEqualStrings(clear, empty);
}

test "Program Status capability ignores unrelated queries" {
    var session: Session = .{};
    try session.init(&osc_definitions);
    defer session.deinit();

    sendReport(&session, "state=blocked:id=child");
    session.stream.nextSlice("\x1b[c\x1b[>c\x1b[5n\x1b[6n\x1b]10;?\x07\x1b]52;c;?\x07");
    const snapshot = try session.snapshot();
    defer alloc.free(snapshot);

    try std.testing.expectEqualStrings(clear ++ "\x1b]7501;state=blocked:id=child\x1b\\", snapshot);
    try std.testing.expectEqualStrings("", session.input.items);
}

test "Program Status capability removes active records on accepted prompt events" {
    for ([_][]const u8{ "\x1b]133;A\x07", "\x1b]133;N\x07", "\x1b]133;P\x07" }) |prompt| {
        var session: Session = .{};
        try session.init(&osc_definitions);
        defer session.deinit();

        sendReport(&session, "state=working");
        sendReport(&session, "state=blocked:id=waiting");
        sendReport(&session, "state=idle:id=idle");
        sendReport(&session, "state=done:id=done");
        sendReport(&session, "state=error:id=error");
        session.stream.nextSlice(prompt);

        const snapshot = try session.snapshot();
        defer alloc.free(snapshot);

        try std.testing.expectEqualStrings(clear ++ "\x1b]7501;state=idle:id=idle\x1b\\\x1b]7501;state=done:id=done\x1b\\\x1b]7501;state=error:id=error\x1b\\", snapshot);
    }
}

test "Program Status capability distinguishes full reset soft reset and unrelated shell events" {
    var session: Session = .{};
    try session.init(&osc_definitions);
    defer session.deinit();

    sendReport(&session, "state=blocked");
    session.stream.nextSlice("\x1b[!p\x1b]133;B\x07\x1b]133;C\x07\x1b]133;D;0\x07");
    const before = try session.snapshot();
    defer alloc.free(before);

    try std.testing.expectEqualStrings(clear ++ "\x1b]7501;state=blocked\x1b\\", before);
    session.stream.nextSlice("\x1bc");
    const after = try session.snapshot();
    defer alloc.free(after);

    try std.testing.expectEqualStrings(clear, after);
}

// Compare complete capability state after reconnecting at every byte boundary.
// This also checks the final byte of ST, which follows query dispatch at ESC.
test "Program Status capability restores interrupted reports clears and queries at every split" {
    const sequences = [_][]const u8{
        "\x1b]7501;state=idle:app=agent\x07",
        "\x1b]7501;state=blocked:id=build/test:kind=permission\x1b\\",
        "\x1b]7501;state=clear:id=build\x1b\\",
        "\x1b]7501;state=clear\x07",
        "\x1b]7501;?\x07",
        "\x1b]7501;?\x1b\\",
    };

    for (sequences) |sequence| {
        for (0..sequence.len + 1) |cut| {
            var source: Session = .{};
            try source.init(&osc_definitions);
            defer source.deinit();

            sendReport(&source, "state=working");
            sendReport(&source, "state=working:id=build/test");
            source.stream.nextSlice(sequence[0..cut]);
            const snapshot = try source.snapshot();
            defer alloc.free(snapshot);

            var target: Session = .{};
            try target.init(&osc_definitions);
            defer target.deinit();

            sendReport(&target, "state=error:id=stale");
            target.stream.nextSlice(snapshot);
            try std.testing.expectEqualStrings("", target.input.items);
            source.stream.nextSlice(sequence[cut..]);
            target.stream.nextSlice(sequence[cut..]);
            const expected = try source.snapshot();
            defer alloc.free(expected);

            const actual = try target.snapshot();
            defer alloc.free(actual);

            try std.testing.expectEqualStrings(expected, actual);
            if (std.mem.indexOf(u8, sequence, ";?") != null) {
                const dispatch_end = sequence.len - @as(usize, if (sequence[sequence.len - 1] == '\\') 1 else 0);
                const terminator: []const u8 = if (sequence[sequence.len - 1] == '\\') "\x1b\\" else "\x07";
                const expected_reply = try std.fmt.allocPrint(alloc, "\x1b]7501;{s}{s}", .{ ghostty.osc.program_status.query_reply, terminator });
                defer alloc.free(expected_reply);

                try std.testing.expectEqualStrings(expected_reply, source.input.items);
                try std.testing.expectEqualStrings(if (cut >= dispatch_end) "" else expected_reply, target.input.items);
            }
        }
    }
}

test "Program Status detached query ownership follows attachment at every byte boundary" {
    inline for (.{ "\x07", "\x1b\\" }) |terminator| {
        const query = "\x1b]7501;?" ++ terminator;
        for ([_]bool{ false, true }) |initially_attached| {
            for (0..query.len + 1) |cut| {
                var session: Session = .{};
                try session.init(&osc_definitions);
                defer session.deinit();

                session.attached = initially_attached;
                session.stream.nextSlice(query[0..cut]);
                session.attached = !initially_attached;
                session.stream.nextSlice(query[cut..]);
                const dispatch_end = query.len - @as(usize, if (terminator.len == 2) 1 else 0);
                const replied = if (cut >= dispatch_end) !initially_attached else initially_attached;
                try std.testing.expectEqualStrings(if (replied) "\x1b]7501;" ++ ghostty.osc.program_status.query_reply ++ terminator else "", session.input.items);
            }
        }
    }
}

test "Program Status capability suppresses incomplete saved state until clear or full reset but preserves unfinished command replay" {
    for ([_][]const u8{ "\x1b]7501;state=clear\x07", "\x1bc" }) |reset| {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
        var session: Session = .{};
        try session.init(&osc_definitions);
        defer session.deinit();

        sendReport(&session, "state=working");

        // Fail saving the task record without also failing Ghostty's parser.
        // Its allocator was captured when the stream was initialized.
        session.host.alloc = failing.allocator();
        sendReport(&session, "state=idle");
        session.host.alloc = alloc;
        try std.testing.expect(failing.has_induced_failure);
        sendReport(&session, "state=done:id=worker");
        sendReport(&session, "state=clear:id=worker");
        session.stream.nextSlice("\x1b]133;A\x07");
        const suppressed = try session.snapshot();
        defer alloc.free(suppressed);

        try std.testing.expectEqualStrings("", suppressed);
        session.stream.nextSlice("\x1b]7501;state=blocked");
        const pending = try session.snapshot();
        defer alloc.free(pending);

        try std.testing.expectEqualStrings("\x1b]7501;state=blocked", pending);
        session.stream.nextSlice("\x07");
        session.stream.nextSlice(reset);
        const recovered = try session.snapshot();
        defer alloc.free(recovered);

        try std.testing.expectEqualStrings(clear, recovered);
    }
}

test "Program Status capability restores a large interrupted report within the protocol limits" {
    const id = repeat("a", 31) ++ "/" ++ repeat("b", 31) ++ "/" ++ repeat("c", 31) ++ "/" ++ repeat("d", 31);
    const report = "state=blocked:kind=permission:progress=100:app=" ++ repeat("a", 32) ++
        ":id=" ++ id ++ ":title=" ++ repeat("YWFh", 64) ++ ":msg=" ++ repeat("YWFh", 682) ++ "YWE=";
    const sequence = "\x1b]7501;" ++ report ++ "\x1b\\";
    for ([_]usize{ 7, 1023, sequence.len - 2, sequence.len - 1, sequence.len }) |cut| {
        var source: Session = .{};
        try source.init(&osc_definitions);
        defer source.deinit();

        source.stream.nextSlice(sequence[0..cut]);
        const snapshot = try source.snapshot();
        defer alloc.free(snapshot);

        var target: Session = .{};
        try target.init(&osc_definitions);
        defer target.deinit();

        target.stream.nextSlice(snapshot);
        source.stream.nextSlice(sequence[cut..]);
        target.stream.nextSlice(sequence[cut..]);
        const expected = try source.snapshot();
        defer alloc.free(expected);

        const actual = try target.snapshot();
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
        try std.testing.expect(std.mem.indexOf(u8, actual, report) != null);
    }
}

test "Program Status capability rejects malformed and oversized reports without changing saved state" {
    var session: Session = .{};
    try session.init(&osc_definitions);
    defer session.deinit();

    sendReport(&session, "state=done:app=test");
    for ([_][]const u8{
        "state=unknown",
        "state=working:id=",
        "state=blocked:id=bad//id",
        "state=blocked:msg=A",
        "state=blocked:msg=Cg==",
        "state=blocked:title=wog=",
        "state=blocked:abcdefghijklmnopq=x",
        "state=blocked:app=" ++ repeat("a", 33),
        "state=blocked:msg=" ++ repeat("YQ==", 684),
        "state=blocked:title=" ++ repeat("YQ==", 65),
        "state=blocked:unknown=" ++ repeat("x", 4096),
    }) |invalid| {
        sendReport(&session, invalid);
        const snapshot = try session.snapshot();
        defer alloc.free(snapshot);

        try std.testing.expectEqualStrings(clear ++ "\x1b]7501;state=done:app=test\x1b\\", snapshot);
    }

    try std.testing.expectEqualStrings("", session.input.items);
}

test "Program Status records survive an oversized unrelated unfinished command" {
    var session: Session = .{};
    try session.init(&osc_definitions);
    defer session.deinit();

    sendReport(&session, "state=blocked:id=worker");
    session.stream.nextSlice("\x1b]52;c;" ++ repeat("YQ==", 1100));
    const unavailable = try session.snapshot();
    defer alloc.free(unavailable);

    try std.testing.expectEqualStrings(clear ++ "\x1b]7501;state=blocked:id=worker\x1b\\", unavailable);
    session.stream.nextSlice("\x07\x1b]7501;state=idle");
    const recovered = try session.snapshot();
    defer alloc.free(recovered);

    try std.testing.expect(std.mem.endsWith(u8, recovered, "\x1b]7501;state=idle"));
}

test "Program Status save failure does not prevent OSC 7 directory restoration" {
    const directory = "\x1b]7;file://localhost/tmp\x1b\\";
    var session: Session = .{};
    try session.init(&.{
        @import("zmx").capability_definitions.working_directory,
        @import("zmx").capability_definitions.program_status,
    });
    defer session.deinit();

    session.stream.nextSlice(directory);
    sendReport(&session, "state=done:app=test");

    // Lose one Program Status update while leaving the shared parser available.
    // A reconnect should still restore the independent directory information.
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    session.host.alloc = failing.allocator();
    sendReport(&session, "state=blocked");
    session.host.alloc = alloc;
    try std.testing.expect(failing.has_induced_failure);
    const incomplete = try session.snapshot();
    defer alloc.free(incomplete);

    try std.testing.expectEqualStrings(directory, incomplete);
    sendReport(&session, "state=clear");
    sendReport(&session, "state=idle");
    const recovered = try session.snapshot();
    defer alloc.free(recovered);

    try std.testing.expectEqualStrings(directory ++ clear ++ "\x1b]7501;state=idle\x1b\\", recovered);
}

test "Program Status capacity allocation failure suppresses restore without leaking copied bytes" {
    var session: Session = .{};
    try session.init(&osc_definitions);
    defer session.deinit();

    // The report's byte copy succeeds, then growing the empty task list fails.
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 1 });
    session.host.alloc = failing.allocator();
    sendReport(&session, "state=working");
    session.host.alloc = alloc;
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
    try std.testing.expect(failing.has_induced_failure);
    const incomplete = try session.snapshot();
    defer alloc.free(incomplete);

    try std.testing.expectEqualStrings("", incomplete);
    sendReport(&session, "state=clear");
    const recovered = try session.snapshot();
    defer alloc.free(recovered);

    try std.testing.expectEqualStrings(clear, recovered);
}

test "Program Status evicts the least recently updated record" {
    var session: Session = .{};
    try session.init(&osc_definitions);
    defer session.deinit();

    var buffer: [64]u8 = undefined;
    for (0..256) |index| {
        sendReport(&session, try std.fmt.bufPrint(&buffer, "state=working:id=task-{d}", .{index}));
    }

    // Refreshing 'task-0' protects it. Adding 'task-256' removes 'task-1' instead.
    sendReport(&session, "state=blocked:id=task-0");
    sendReport(&session, "state=working:id=task-256");
    const restored = try session.snapshot();
    defer alloc.free(restored);

    var expected: std.Io.Writer.Allocating = .init(alloc);
    defer expected.deinit();

    try expected.writer.writeAll(clear);
    for (2..256) |index| {
        try expected.writer.print("\x1b]7501;state=working:id=task-{d}\x1b\\", .{index});
    }

    try expected.writer.writeAll("\x1b]7501;state=blocked:id=task-0\x1b\\\x1b]7501;state=working:id=task-256\x1b\\");
    try std.testing.expectEqualStrings(expected.writer.buffered(), restored);
}
