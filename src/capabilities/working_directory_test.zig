//! Check the real OSC 7 capability using Ghostty's directory state.
const std = @import("std");
const Session = @import("test_session.zig").Session;
const alloc = std.testing.allocator;
const clear = "\x1b]7501;state=clear\x1b\\";

test "OSC 7 restores the latest directory without a NUL sentinel" {
    var session: Session = .{};
    try session.init();
    defer session.deinit();

    const empty = try session.snapshot();
    defer alloc.free(empty);

    try std.testing.expectEqualStrings(clear, empty);
    try std.testing.expect(session.term.getPwd() == null);
    session.stream.nextSlice("\x1b]7;file://localhost/old\x07\x1b]7;file://otherhost/new%20directory\x1b\\");
    const restored = try session.snapshot();
    defer alloc.free(restored);

    try std.testing.expectEqualStrings("\x1b]7;file://otherhost/new%20directory\x1b\\" ++ clear, restored);
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
            try session.init();
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

            try std.testing.expectEqualStrings("\x1b]7;file://localhost/tmp\x1b\\" ++ clear, restored);
        }
    }
}

test "OSC 7 follows terminal reset without keeping an older directory" {
    var session: Session = .{};
    try session.init();
    defer session.deinit();

    session.stream.nextSlice("\x1b]7;file://localhost/old\x07\x1bc");
    try std.testing.expect(session.term.getPwd() == null);
    const cleared = try session.snapshot();
    defer alloc.free(cleared);

    try std.testing.expectEqualStrings(clear, cleared);
    session.stream.nextSlice("\x1b]7;file://localhost/recovered\x07");
    const recovered = try session.snapshot();
    defer alloc.free(recovered);

    try std.testing.expectEqualStrings("\x1b]7;file://localhost/recovered\x1b\\" ++ clear, recovered);
}

test "OSC 7 and Program Status restore in handler order and follow reset" {
    const directory = "\x1b]7;file://localhost/tmp\x1b\\";
    const status = clear ++ "\x1b]7501;state=blocked:id=build\x1b\\";
    var session: Session = .{};
    try session.init();
    defer session.deinit();
    session.stream.nextSlice(directory ++ "\x1b]7501;state=blocked:id=build\x07");
    const restored = try session.snapshot();
    defer alloc.free(restored);
    try std.testing.expectEqualStrings(directory ++ status, restored);
    session.stream.nextSlice("\x1bc");
    const reset = try session.snapshot();
    defer alloc.free(reset);
    try std.testing.expectEqualStrings(clear, reset);
    try std.testing.expect(session.term.getPwd() == null);
}
