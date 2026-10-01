//! The fork's remote vocabulary is separate from the current daemon protocol.
const std = @import("std");
const zmx = @import("libzmx");

pub const header_len = 8;
pub const max_payload = 1024 * 1024;
pub const max_buffer = max_payload + @sizeOf(zmx.ipc.Header);
pub const Tag = enum(u8) { Input = 0, Output = 1, Resize = 2, Detach = 3, Init = 7, SessionEnd = 11 };
pub const Message = struct { tag: Tag, data: []const u8 };

// Preserve the pinned fork's eight-byte little-endian packed-header encoding,
// including zero padding, without exposing native tag assignments over UDP.
pub fn encode(tag: Tag, data: []const u8, out: []u8) ![]const u8 {
    if (data.len > max_payload or out.len < header_len + data.len) return error.MessageTooLarge;
    @memset(out[0..header_len], 0);
    out[0] = @intFromEnum(tag);
    std.mem.writeInt(u32, out[1..5], @intCast(data.len), .little);
    @memcpy(out[header_len..][0..data.len], data);
    return out[0 .. header_len + data.len];
}

pub fn decode(data: []const u8) !Message {
    if (data.len < header_len) return error.TruncatedMessage;
    const len = std.mem.readInt(u32, data[1..5], .little);
    if (len > max_payload or data.len != header_len + @as(usize, len)) return error.InvalidLength;
    if (!std.mem.eql(u8, data[5..8], &.{ 0, 0, 0 })) return error.InvalidPadding;
    return .{ .tag = std.enums.fromInt(Tag, data[0]) orelse return error.UnknownTag, .data = data[header_len..] };
}

pub fn encodeSize(size: zmx.ipc.Resize) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], size.rows, .little);
    std.mem.writeInt(u16, bytes[2..4], size.cols, .little);
    return bytes;
}

pub fn decodeSize(data: []const u8) !zmx.ipc.Resize {
    if (data.len != 4) return error.InvalidSize;
    const rows = std.mem.readInt(u16, data[0..2], .little);
    const cols = std.mem.readInt(u16, data[2..4], .little);
    if (rows == 0 or cols == 0) return error.InvalidSize;
    return .{ .rows = rows, .cols = cols };
}

/// Validate the entire remote record before admitting it to native IPC.
pub fn appendNative(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: Message) !void {
    switch (msg.tag) {
        .Input => try zmx.ipc.appendMessage(alloc, out, .Input, msg.data),
        .Init, .Resize => {
            const size = try decodeSize(msg.data);
            try zmx.ipc.appendSizeMessage(alloc, out, if (msg.tag == .Init) .Init else .Resize, size);
        },
        .Detach => {
            if (msg.data.len != 0) return error.InvalidLength;
            try zmx.ipc.appendMessage(alloc, out, .Detach, "");
        },
        .Output, .SessionEnd => return error.ForbiddenMessage,
    }
}

/// A bounded native decoder: reject the length as soon as the header arrives.
/// Read only `remaining()` bytes to avoid buffering a second frame behind a
/// maximum-sized snapshot. The caller consumes a frame before reading more.
pub const NativeFrame = struct {
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *NativeFrame, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
    }

    pub fn remaining(self: *const NativeFrame) !usize {
        const size = @sizeOf(zmx.ipc.Header);
        if (self.bytes.items.len < size) return size - self.bytes.items.len;
        const h = std.mem.bytesToValue(zmx.ipc.Header, self.bytes.items[0..size]);
        if (h.len > max_payload) return error.NativeFrameTooLarge;
        return size + @as(usize, h.len) - self.bytes.items.len;
    }

    pub fn append(self: *NativeFrame, alloc: std.mem.Allocator, data: []const u8) !void {
        if (data.len > try self.remaining()) return error.InvalidLength;
        try self.bytes.appendSlice(alloc, data);
        _ = try self.remaining();
    }

    pub fn message(self: *const NativeFrame) !?zmx.ipc.SocketMsg {
        if (try self.remaining() != 0) return null;
        const size = @sizeOf(zmx.ipc.Header);
        return .{ .header = std.mem.bytesToValue(zmx.ipc.Header, self.bytes.items[0..size]), .payload = self.bytes.items[size..] };
    }

    pub fn clear(self: *NativeFrame) void {
        self.bytes.clearRetainingCapacity();
    }
};

test "remote terminal end cannot become native Switch" {
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(zmx.ipc.Tag.Switch));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.ForbiddenMessage, appendNative(std.testing.allocator, &out, .{ .tag = .SessionEnd, .data = "" }));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "remote size translates to native and legacy encodings" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const data = encodeSize(.{ .rows = 31, .cols = 97 });
    try appendNative(std.testing.allocator, &out, .{ .tag = .Init, .data = &data });
    const h = std.mem.bytesToValue(zmx.ipc.Header, out.items[0..8]);
    try std.testing.expectEqual(zmx.ipc.Tag.Init, h.tag);
    try std.testing.expectEqual(@as(u32, 8), h.len);
    const size = std.mem.bytesToValue(zmx.ipc.Resize, out.items[8..16]);
    try std.testing.expectEqual(@as(u16, 31), size.rows);
    try std.testing.expectEqual(@as(u16, 97), size.cols);
    try std.testing.expectEqual(@as(u16, 0), size.xpixel);
    try std.testing.expectEqual(@as(usize, 28), out.items.len);
}

test "native frame length is bounded before reading payload" {
    for ([_]u32{ max_payload - 1, max_payload, max_payload + 1 }) |len| {
        var frame: NativeFrame = .{};
        defer frame.deinit(std.testing.allocator);
        const h = zmx.ipc.Header{ .tag = .Output, .len = len };
        if (len > max_payload) {
            try std.testing.expectError(error.NativeFrameTooLarge, frame.append(std.testing.allocator, std.mem.asBytes(&h)));
        } else {
            try frame.append(std.testing.allocator, std.mem.asBytes(&h)[0..3]);
            try frame.append(std.testing.allocator, std.mem.asBytes(&h)[3..]);
            try std.testing.expectEqual(@as(usize, len), try frame.remaining());
            try std.testing.expectEqual(@as(usize, 8), frame.bytes.items.len);
        }
    }
}

test "wire rejects unknown tags, truncation and trailing bytes" {
    var bytes: [64]u8 = undefined;
    const encoded = try encode(.Input, "hello", &bytes);
    try std.testing.expectEqualStrings("hello", (try decode(encoded)).data);
    try std.testing.expectError(error.InvalidLength, decode(encoded[0 .. encoded.len - 1]));
    bytes[0] = @intFromEnum(zmx.ipc.Tag.Kill);
    try std.testing.expectError(error.UnknownTag, decode(encoded));
}
