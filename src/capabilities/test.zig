const std = @import("std");
const ghostty = @import("ghostty-vt");
const Session = @import("test_session.zig").Session;
const alloc = std.testing.allocator;

test "capability dispatch preserves Ghostty's screen and directory updates" {
    var session: Session = .{};
    try session.init();
    defer session.deinit();
    var expected_term = try ghostty.Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer expected_term.deinit(alloc);
    var expected_stream = expected_term.vtStream();
    defer expected_stream.deinit();

    const bytes = "hello\x1b[2D!!\x1b]7;file://localhost/tmp\x07";
    session.stream.nextSlice(bytes);
    expected_stream.nextSlice(bytes);
    const actual = try session.term.plainString(alloc);
    defer alloc.free(actual);
    const expected = try expected_term.plainString(alloc);
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqualStrings(expected_term.getPwd().?, session.term.getPwd().?);
    try std.testing.expectEqualStrings("", session.input.items);
}

test "reconnect resumes an unfinished command after complete restore messages" {
    var session: Session = .{};
    try session.init();
    defer session.deinit();
    session.stream.nextSlice("visible\x1b]0;unfinished");
    const snapshot = try session.snapshot();
    defer alloc.free(snapshot);
    try std.testing.expect(std.mem.endsWith(u8, snapshot, "\x1b]0;unfinished"));
    session.stream.nextSlice(" title\x07");
    const completed = try session.snapshot();
    defer alloc.free(completed);
    try std.testing.expect(std.mem.indexOf(u8, completed, "unfinished") == null);
}
