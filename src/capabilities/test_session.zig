//! In-memory daemon state for capability tests; no shells or live sessions.
const std = @import("std");
const capabilities = @import("../capabilities.zig");
const ghostty = @import("ghostty-vt");
const alloc = std.testing.allocator;

/// A 'Session' owns a test terminal, parser, and handlers at stable addresses.
pub const Session = struct {
    term: ghostty.Terminal = undefined,
    host: capabilities.Session = undefined,
    stream: capabilities.Stream = undefined,
    attached: bool = false,
    input: std.ArrayList(u8) = .empty,

    pub fn init(self: *Session) !void {
        self.term = try ghostty.Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
        self.host = capabilities.Session.init(alloc);
        self.stream = capabilities.initStream(&self.term, &self.host, .{
            .context = self,
            .isAttached = isAttached,
            .write = reply,
        });
    }

    pub fn deinit(self: *Session) void {
        self.stream.deinit();
        self.host.deinit();
        self.term.deinit(alloc);
        self.input.deinit(alloc);
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
        capabilities.restore(&self.stream, .{ .context = buffer, .write = append });
    }

    fn append(context: *anyopaque, bytes: []const u8) !void {
        const buffer: *std.Io.Writer.Allocating = @ptrCast(@alignCast(context));
        try buffer.writer.writeAll(bytes);
    }

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
