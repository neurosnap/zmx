//! Check the real OSC 7 capability using Ghostty's directory state.
const std = @import("std");
const api = @import("zmx").capabilities;
const definition = @import("zmx").capability_definitions.working_directory;
const Session = @import("../capabilities/session.zig").Session;
const alloc = std.testing.allocator;

test "OSC 7 restores the latest directory without a NUL sentinel" {
    var session: Session = .{};
    try session.init(&.{definition});
    defer session.deinit();

    const empty = try session.snapshot();
    defer alloc.free(empty);

    try std.testing.expectEqualStrings("", empty);
    try std.testing.expect(session.term.getPwd() == null);
    session.stream.nextSlice("\x1b]7;file://localhost/old\x07\x1b]7;file://otherhost/new%20directory\x1b\\");
    const restored = try session.snapshot();
    defer alloc.free(restored);

    try std.testing.expectEqualStrings("\x1b]7;file://otherhost/new%20directory\x1b\\", restored);
    try std.testing.expectEqualStrings("file://otherhost/new%20directory", session.term.getPwd().?);
    try std.testing.expect(std.mem.indexOfScalar(u8, restored, 0) == null);
    try std.testing.expectEqualStrings("", session.input.items);
}

test "OSC 7 waits for the whole message across every split" {
    for ([_][]const u8{ "\x07", "\x1b\\" }) |terminator| {
        const message = try std.fmt.allocPrint(alloc, "\x1b]7;file://localhost/tmp{s}", .{terminator});
        defer alloc.free(message);

        for (0..message.len) |split| {
            var session: Session = .{};
            try session.init(&.{definition});
            defer session.deinit();

            session.stream.nextSlice(message[0..split]);

            // Ghostty accepts an OSC command at BEL or the ESC of an ST ending.
            // Its parser then consumes the trailing backslash separately.
            const accepted_at = message.len - terminator.len + 1;
            if (split < accepted_at) {
                try std.testing.expect(session.term.getPwd() == null);
            }

            session.stream.nextSlice(message[split..]);
            try std.testing.expectEqualStrings("file://localhost/tmp", session.term.getPwd().?);
            const restored = try session.snapshot();
            defer alloc.free(restored);

            try std.testing.expectEqualStrings("\x1b]7;file://localhost/tmp\x1b\\", restored);
        }
    }
}

test "OSC 7 follows terminal reset without keeping an older directory" {
    var session: Session = .{};
    try session.init(&.{definition});
    defer session.deinit();

    session.stream.nextSlice("\x1b]7;file://localhost/old\x07\x1bc");
    try std.testing.expect(session.term.getPwd() == null);
    const cleared = try session.snapshot();
    defer alloc.free(cleared);

    try std.testing.expectEqualStrings("", cleared);
    session.stream.nextSlice("\x1b]7;file://localhost/recovered\x07");
    const recovered = try session.snapshot();
    defer alloc.free(recovered);

    try std.testing.expectEqualStrings("\x1b]7;file://localhost/recovered\x1b\\", recovered);
}

test "OSC 7 and Program Status restore independently in either configured order" {
    const program_status = @import("zmx").capability_definitions.program_status;
    const directory = "\x1b]7;file://localhost/tmp\x1b\\";
    const status = "\x1b]7501;state=clear\x1b\\\x1b]7501;state=blocked:id=build\x1b\\";
    for ([_][2]api.Definition{ .{ definition, program_status }, .{ program_status, definition } }, 0..) |definitions, index| {
        var session: Session = .{};
        try session.init(&definitions);
        defer session.deinit();

        session.stream.nextSlice(directory ++ "\x1b]7501;state=blocked:id=build\x07");
        const restored = try session.snapshot();
        defer alloc.free(restored);

        try std.testing.expectEqualStrings(if (index == 0) directory ++ status else status ++ directory, restored);
        session.stream.nextSlice("\x1bc");
        const reset = try session.snapshot();
        defer alloc.free(reset);

        try std.testing.expectEqualStrings("\x1b]7501;state=clear\x1b\\", reset);
        try std.testing.expect(session.term.getPwd() == null);
    }
}

test "required working directory behavior does not enable Program Status" {
    var session: Session = .{};
    try session.init(&.{definition});
    defer session.deinit();

    // A detached daemon must not promise task tracking unless that optional
    // capability is enabled, even though working directory restoration is active.
    session.stream.nextSlice("\x1b]7;file://localhost/tmp\x07\x1b]7501;?\x07\x1b]7501;state=working\x07");
    try std.testing.expectEqualStrings("", session.input.items);
    const restored = try session.snapshot();
    defer alloc.free(restored);

    try std.testing.expectEqualStrings("\x1b]7;file://localhost/tmp\x1b\\", restored);
}
