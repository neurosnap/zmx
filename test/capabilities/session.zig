//! A terminal and capability session for tests without shells or real zmx sessions.
const std = @import("std");
const api = @import("zmx").capabilities;
const runtime = @import("capability-runtime");
const ghostty = @import("ghostty-vt");
const alloc = std.testing.allocator;

/// A 'Session' is an in-memory terminal and capability session for unit tests.
/// Tests feed bytes into 'stream' and inspect 'input' for answers sent to the program.
/// Keep this value at its initialized address because callbacks point to its fields.
pub const Session = struct {
    term: ghostty.Terminal = undefined,
    host: runtime.Session = undefined,
    stream: runtime.Stream = undefined,
    attached: bool = false,
    input: std.ArrayList(u8) = .empty,

    pub fn init(self: *Session, definitions: []const api.Definition) !void {
        self.term = try ghostty.Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
        errdefer self.term.deinit(alloc);

        self.host = try runtime.Session.init(alloc, definitions);
        self.stream = runtime.initStream(&self.term, &self.host, self.replies());
    }

    pub fn deinit(self: *Session) void {
        self.stream.deinit();
        self.host.deinit();
        self.term.deinit(alloc);
        self.input.deinit(alloc);
    }

    fn replies(self: *Session) runtime.Replies {
        return .{ .context = self, .isAttached = isAttached, .write = reply };
    }

    fn isAttached(context: *anyopaque) bool {
        const self: *Session = @ptrCast(@alignCast(context));
        return self.attached;
    }

    fn reply(context: *anyopaque, _: std.mem.Allocator, bytes: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.input.appendSlice(alloc, bytes) catch @panic("test allocation failed");
    }

    pub fn restore(self: *Session, buffer: *std.Io.Writer.Allocating) void {
        runtime.restore(&self.stream, .{ .context = buffer, .write = append });
    }

    fn append(context: *anyopaque, bytes: []const u8) !void {
        const buffer: *std.Io.Writer.Allocating = @ptrCast(@alignCast(context));
        try buffer.writer.writeAll(bytes);
    }

    /// Return the capability reconnect messages and any unfinished terminal command.
    /// The test owns the returned bytes. This does not include a screen restoration.
    pub fn snapshot(self: *Session) ![]u8 {
        var buffer: std.Io.Writer.Allocating = .init(alloc);
        defer buffer.deinit();

        self.restore(&buffer);
        return alloc.dupe(u8, buffer.writer.buffered());
    }
};

pub fn repeat(comptime bytes: []const u8, comptime count: usize) [bytes.len * count]u8 {
    var result: [bytes.len * count]u8 = undefined;
    for (0..count) |index| {
        @memcpy(result[index * bytes.len ..][0..bytes.len], bytes);
    }

    return result;
}
