//! OSC 7 restores the working directory from Ghostty's saved terminal state.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const api = @import("../capabilities.zig");
const Self = @This();

pub fn deinit(_: *Self, _: std.mem.Allocator) void {}
pub fn observe(_: *Self, _: std.mem.Allocator, _: api.Event, _: *api.Reply) void {}

/// Write the OSC 7 message that restores this session's working directory.
pub fn restore(_: *Self, term: *const ghostty.Terminal, writer: *std.Io.Writer) !void {
    // Ghostty already tracks OSC 7. Read its value instead of keeping a second copy.
    const pwd = term.getPwd() orelse return;
    if (pwd.len == 0) return;

    // getPwd omits the internal NUL sentinel, which must not reach the client.
    // github.com/neurosnap/zmx/issues/222
    try writer.print("\x1b]7;{s}\x1b\\", .{pwd});
}
