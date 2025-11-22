const std = @import("std");
const posix = std.posix;

pub const Tag = enum(u8) {
    Input = 0,
    Output = 1,
    Resize = 2,
    Pid = 3,
};

pub const Header = packed struct {
    tag: Tag,
    len: u32,
};

pub const Resize = packed struct {
    rows: u16,
    cols: u16,
};

pub const Pid = packed struct {
    pid: i32,
};

pub fn expectedLength(data: []const u8) ?usize {
    if (data.len < @sizeOf(Header)) return null;
    const header = std.mem.bytesToValue(Header, data[0..@sizeOf(Header)]);
    return @sizeOf(Header) + header.len;
}

pub fn send(fd: i32, tag: Tag, data: []const u8) !void {
    const header = Header{
        .tag = tag,
        .len = @intCast(data.len),
    };
    const header_bytes = std.mem.asBytes(&header);
    try writeAll(fd, header_bytes);
    if (data.len > 0) {
        try writeAll(fd, data);
    }
}

pub fn sendStruct(fd: i32, tag: Tag, payload: anytype) !void {
    const bytes = std.mem.asBytes(&payload);
    return send(fd, tag, bytes);
}

pub fn appendMessage(alloc: std.mem.Allocator, list: *std.ArrayList(u8), tag: Tag, data: []const u8) !void {
    const header = Header{
        .tag = tag,
        .len = @intCast(data.len),
    };
    try list.appendSlice(alloc, std.mem.asBytes(&header));
    if (data.len > 0) {
        try list.appendSlice(alloc, data);
    }
}

fn writeAll(fd: i32, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const n = try posix.write(fd, data[index..]);
        if (n == 0) return error.DiskQuota;
        index += n;
    }
}

pub const Message = struct {
    tag: Tag,
    data: []u8,

    pub fn deinit(self: Message, alloc: std.mem.Allocator) void {
        if (self.data.len > 0) {
            alloc.free(self.data);
        }
    }
};

pub const SocketBuffer = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !SocketBuffer {
        return .{
            .buf = try std.ArrayList(u8).initCapacity(alloc, 4096),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *SocketBuffer) void {
        self.buf.deinit(self.alloc);
    }

    /// Reads from fd into buffer.
    /// Returns number of bytes read.
    /// Propagates error.WouldBlock and other errors to caller.
    /// Returns 0 on EOF.
    pub fn read(self: *SocketBuffer, fd: i32) !usize {
        var tmp: [4096]u8 = undefined;
        const n = try posix.read(fd, &tmp);
        if (n > 0) {
            try self.buf.appendSlice(self.alloc, tmp[0..n]);
        }
        return n;
    }

    /// Process all complete messages in the buffer.
    /// callback is called for each message.
    /// The payload slice is valid only during the callback execution.
    pub fn process(self: *SocketBuffer, context: anytype, callback: fn (ctx: @TypeOf(context), header: Header, payload: []u8) anyerror!void) !void {
        while (true) {
            const total_len = expectedLength(self.buf.items) orelse break;
            if (self.buf.items.len < total_len) break;

            const header = std.mem.bytesToValue(Header, self.buf.items[0..@sizeOf(Header)]);
            const payload = self.buf.items[@sizeOf(Header)..total_len];

            try callback(context, header, payload);

            try self.buf.replaceRange(self.alloc, 0, total_len, &[_]u8{});
        }
    }
};
