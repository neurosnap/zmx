const std = @import("std");
const posix = std.posix;

// Message types enum for type-safe dispatching
pub const MessageType = enum {
    // Client -> Daemon requests
    attach_session_request,
    detach_session_request,
    kill_session_request,
    list_sessions_request,
    pty_in,
    window_resize,

    // Daemon -> Client responses
    attach_session_response,
    detach_session_response,
    kill_session_response,
    list_sessions_response,
    pty_out,

    // Daemon -> Client notifications
    detach_notification,
    kill_notification,

    pub fn toString(self: MessageType) []const u8 {
        return switch (self) {
            .attach_session_request => "attach_session_request",
            .detach_session_request => "detach_session_request",
            .kill_session_request => "kill_session_request",
            .list_sessions_request => "list_sessions_request",
            .pty_in => "pty_in",
            .window_resize => "window_resize",
            .attach_session_response => "attach_session_response",
            .detach_session_response => "detach_session_response",
            .kill_session_response => "kill_session_response",
            .list_sessions_response => "list_sessions_response",
            .pty_out => "pty_out",
            .detach_notification => "detach_notification",
            .kill_notification => "kill_notification",
        };
    }

    pub fn fromString(s: []const u8) ?MessageType {
        const map = std.StaticStringMap(MessageType).initComptime(.{
            .{ "attach_session_request", .attach_session_request },
            .{ "detach_session_request", .detach_session_request },
            .{ "kill_session_request", .kill_session_request },
            .{ "list_sessions_request", .list_sessions_request },
            .{ "pty_in", .pty_in },
            .{ "window_resize", .window_resize },
            .{ "attach_session_response", .attach_session_response },
            .{ "detach_session_response", .detach_session_response },
            .{ "kill_session_response", .kill_session_response },
            .{ "list_sessions_response", .list_sessions_response },
            .{ "pty_out", .pty_out },
            .{ "detach_notification", .detach_notification },
            .{ "kill_notification", .kill_notification },
        });
        return map.get(s);
    }
};

// Typed payload structs for requests
pub const AttachSessionRequest = struct {
    session_name: []const u8,
    rows: u16,
    cols: u16,
};

pub const DetachSessionRequest = struct {
    session_name: []const u8,
    client_fd: ?i64 = null,
};

pub const KillSessionRequest = struct {
    session_name: []const u8,
};

pub const ListSessionsRequest = struct {};

pub const PtyInput = struct {
    text: []const u8,
};

pub const WindowResize = struct {
    rows: u16,
    cols: u16,
};

// Typed payload structs for responses
pub const SessionInfo = struct {
    name: []const u8,
    status: []const u8,
    clients: i64,
    created_at: []const u8,
};

pub const AttachSessionResponse = struct {
    status: []const u8,
    client_fd: ?i64 = null,
    error_message: ?[]const u8 = null,
};

pub const DetachSessionResponse = struct {
    status: []const u8,
    error_message: ?[]const u8 = null,
};

pub const KillSessionResponse = struct {
    status: []const u8,
    error_message: ?[]const u8 = null,
};

pub const ListSessionsResponse = struct {
    status: []const u8,
    sessions: []SessionInfo = &.{},
    error_message: ?[]const u8 = null,
};

pub const PtyOutput = struct {
    text: []const u8,
};

pub const DetachNotification = struct {
    session_name: []const u8,
};

pub const KillNotification = struct {
    session_name: []const u8,
};

// Generic message wrapper
pub fn Message(comptime T: type) type {
    return struct {
        type: []const u8,
        payload: T,
    };
}

// Helper to write a JSON message to a file descriptor
pub fn writeJson(allocator: std.mem.Allocator, fd: posix.fd_t, msg_type: MessageType, payload: anytype) !void {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const msg = Message(@TypeOf(payload)){
        .type = msg_type.toString(),
        .payload = payload,
    };

    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.write(msg);
    try out.writer.writeByte('\n');

    _ = try posix.write(fd, out.written());
}

// Helper to write a raw JSON response (for complex cases like list_sessions with dynamic arrays)
pub fn writeJsonRaw(fd: posix.fd_t, json_str: []const u8) !void {
    _ = try posix.write(fd, json_str);
}

// Helper to parse a JSON message from a line
pub fn parseMessage(comptime T: type, allocator: std.mem.Allocator, line: []const u8) !std.json.Parsed(Message(T)) {
    return try std.json.parseFromSlice(
        Message(T),
        allocator,
        line,
        .{ .ignore_unknown_fields = true },
    );
}

// Helper to parse just the message type from a line (for dispatching)
const MessageTypeOnly = struct { type: []const u8 };
pub fn parseMessageType(allocator: std.mem.Allocator, line: []const u8) !std.json.Parsed(MessageTypeOnly) {
    return try std.json.parseFromSlice(
        MessageTypeOnly,
        allocator,
        line,
        .{ .ignore_unknown_fields = true },
    );
}

// NDJSON line buffering helper
pub const LineBuffer = struct {
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) LineBuffer {
        return .{ .buffer = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *LineBuffer) void {
        self.buffer.deinit();
    }

    // Append new data and return an iterator over complete lines
    pub fn appendData(self: *LineBuffer, data: []const u8) !LineIterator {
        try self.buffer.appendSlice(data);
        return LineIterator{ .buffer = &self.buffer };
    }

    pub const LineIterator = struct {
        buffer: *std.ArrayList(u8),
        offset: usize = 0,

        pub fn next(self: *LineIterator) ?[]const u8 {
            if (self.offset >= self.buffer.items.len) return null;

            const remaining = self.buffer.items[self.offset..];
            const newline_idx = std.mem.indexOf(u8, remaining, "\n") orelse return null;

            const line = remaining[0..newline_idx];
            self.offset += newline_idx + 1;
            return line;
        }

        // Call this after iteration to remove processed lines
        pub fn compact(self: *LineIterator) void {
            if (self.offset > 0) {
                const remaining = self.buffer.items[self.offset..];
                std.mem.copyForwards(u8, self.buffer.items, remaining);
                self.buffer.shrinkRetainingCapacity(remaining.len);
            }
        }
    };
};

// Future: Binary frame support for PTY data
// This infrastructure allows us to add binary framing later without breaking existing code
pub const FrameType = enum(u16) {
    json_control = 1, // JSON-encoded control messages (current protocol)
    pty_binary = 2, // Raw PTY bytes (future optimization)
};

pub const FrameHeader = packed struct {
    length: u32, // little-endian, total payload length
    frame_type: u16, // little-endian, FrameType value
};

// Future: Helper to write a binary frame (not used yet)
pub fn writeBinaryFrame(fd: posix.fd_t, frame_type: FrameType, payload: []const u8) !void {
    const header = FrameHeader{
        .length = @intCast(payload.len),
        .frame_type = @intFromEnum(frame_type),
    };

    const header_bytes = std.mem.asBytes(&header);
    _ = try posix.write(fd, header_bytes);
    _ = try posix.write(fd, payload);
}

// Future: Helper to read a binary frame (not used yet)
pub fn readBinaryFrame(allocator: std.mem.Allocator, fd: posix.fd_t) !struct { frame_type: FrameType, payload: []u8 } {
    var header_bytes: [@sizeOf(FrameHeader)]u8 = undefined;
    const read_len = try posix.read(fd, &header_bytes);
    if (read_len != @sizeOf(FrameHeader)) return error.IncompleteFrame;

    const header: *const FrameHeader = @ptrCast(@alignCast(&header_bytes));
    const payload = try allocator.alloc(u8, header.length);
    errdefer allocator.free(payload);

    const payload_read = try posix.read(fd, payload);
    if (payload_read != header.length) return error.IncompleteFrame;

    return .{
        .frame_type = @enumFromInt(header.frame_type),
        .payload = payload,
    };
}

// Tests
test "MessageType string conversion" {
    const attach = MessageType.attach_session_request;
    try std.testing.expectEqualStrings("attach_session_request", attach.toString());

    const parsed = MessageType.fromString("attach_session_request");
    try std.testing.expect(parsed != null);
    try std.testing.expectEqual(MessageType.attach_session_request, parsed.?);
}

test "LineBuffer iteration" {
    const allocator = std.testing.allocator;
    var buf = LineBuffer.init(allocator);
    defer buf.deinit();

    var iter = try buf.appendData("line1\nline2\n");
    try std.testing.expectEqualStrings("line1", iter.next().?);
    try std.testing.expectEqualStrings("line2", iter.next().?);
    try std.testing.expect(iter.next() == null);
    iter.compact();

    // Incomplete line should remain
    iter = try buf.appendData("incomplete");
    try std.testing.expect(iter.next() == null);
    iter.compact();
    try std.testing.expectEqual(10, buf.buffer.items.len);

    // Complete the line
    iter = try buf.appendData(" line\n");
    try std.testing.expectEqualStrings("incomplete line", iter.next().?);
    iter.compact();
    try std.testing.expectEqual(0, buf.buffer.items.len);
}
