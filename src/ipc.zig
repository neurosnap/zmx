const std = @import("std");
const posix = std.posix;
const cross = @import("cross.zig");
const socket = @import("socket.zig");

pub const Tag = enum(u8) {
    Input = 0,
    Output = 1,
    Resize = 2,
    Detach = 3,
    DetachAll = 4,
    Kill = 5,
    Info = 6,
    Init = 7,
    History = 8,
    Run = 9,
    Ack = 10,
    Switch = 11,
    Write = 12,
    TaskComplete = 13,
    // Non-exhaustive: this enum comes off the wire via bytesToValue and
    // @enumFromInt, so out-of-range values (14-255) are representable
    // rather than UB. Switches must handle `_` (unknown tag).
    _,
};

comptime {
    if (@typeInfo(Tag).@"enum".is_exhaustive) @compileError(
        "ipc.Tag must stay non-exhaustive — old daemons rely on `_` to ignore unknown tags",
    );
}

pub const Header = packed struct {
    tag: Tag,
    len: u32,
};

pub const Resize = packed struct {
    rows: u16,
    cols: u16,
};

pub fn getTerminalSize(fd: i32) Resize {
    var ws: cross.c.struct_winsize = undefined;
    if (cross.c.ioctl(fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
    return .{ .rows = 24, .cols = 80 };
}

pub const MAX_CMD_LEN = 256;
pub const MAX_CWD_LEN = 256;

/// Frozen wire shape. Do NOT add fields — new stats go in new `Tag` values
/// so old daemons (whose `_` arm ignores unknown tags) stay reachable.
/// Changing `@sizeOf(Info)` breaks `zmx list` against running daemons.
pub const Info = extern struct {
    clients_len: u64,
    pid: i32,
    cmd_len: u16,
    cwd_len: u16,
    cmd: [MAX_CMD_LEN]u8,
    cwd: [MAX_CWD_LEN]u8,
    created_at: u64,
    task_ended_at: u64,
    task_exit_code: u8,
};

pub fn expectedLength(data: []const u8) ?usize {
    if (data.len < @sizeOf(Header)) return null;
    const header = std.mem.bytesToValue(Header, data[0..@sizeOf(Header)]);
    // header.len comes off the wire; widen to usize before adding so a
    // near-u32-max value can't wrap (panic in safe mode, UB in release).
    return @as(usize, @sizeOf(Header)) + @as(usize, header.len);
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

pub fn appendMessage(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(u8),
    tag: Tag,
    data: []const u8,
) !void {
    std.log.info("sending ipc message tag={s}", .{@tagName(tag)});
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

pub const SocketMsg = struct {
    header: Header,
    payload: []const u8,
};

pub const SocketBuffer = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    head: usize,

    pub fn init(alloc: std.mem.Allocator) !SocketBuffer {
        return .{
            .buf = try std.ArrayList(u8).initCapacity(alloc, 4096),
            .alloc = alloc,
            .head = 0,
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
        if (self.head > 0) {
            const remaining = self.buf.items.len - self.head;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.head..]);
                self.buf.items.len = remaining;
            } else {
                self.buf.clearRetainingCapacity();
            }
            self.head = 0;
        }

        var tmp: [4096]u8 = undefined;
        const n = try posix.read(fd, &tmp);
        if (n > 0) {
            try self.buf.appendSlice(self.alloc, tmp[0..n]);
        }
        return n;
    }

    /// Returns the next complete message or `null` when none available.
    /// `buf` is advanced automatically; caller keeps the returned slices
    /// valid until the following `next()` (or `deinit`).
    pub fn next(self: *SocketBuffer) ?SocketMsg {
        const available = self.buf.items[self.head..];
        const total = expectedLength(available) orelse return null;
        if (available.len < total) return null;

        const hdr = std.mem.bytesToValue(Header, available[0..@sizeOf(Header)]);
        const pay = available[@sizeOf(Header)..total];

        self.head += total;
        return .{ .header = hdr, .payload = pay };
    }
};

const ConnectError = error{
    ConnectionRefused,
    Unexpected,
};

/// Connect-only liveness check. Callers that don't read `Info` should use
/// this (not `probeSession`) so they survive `Info` shape changes.
pub fn connectSession(socket_path: []const u8) ConnectError!i32 {
    return socket.sessionConnect(socket_path) catch |err| switch (err) {
        error.ConnectionRefused => return error.ConnectionRefused,
        else => return error.Unexpected,
    };
}

const SessionProbeError = error{
    Timeout,
    ConnectionRefused,
    Unexpected,
    InfoSizeMismatch,
};

const SessionProbeResult = struct {
    fd: i32,
    info: Info,
};

pub fn probeSession(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
) SessionProbeError!SessionProbeResult {
    const timeout_ms = 1000;
    const fd = try connectSession(socket_path);
    errdefer posix.close(fd);

    send(fd, .Info, "") catch return error.Unexpected;

    var poll_fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const poll_result = posix.poll(&poll_fds, timeout_ms) catch return error.Unexpected;
    if (poll_result == 0) {
        return error.Timeout;
    }

    var sb = SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();

    const n = sb.read(fd) catch return error.Unexpected;
    if (n == 0) return error.Unexpected;

    while (sb.next()) |msg| {
        if (msg.header.tag == .Info) {
            if (msg.payload.len != @sizeOf(Info)) return error.InfoSizeMismatch;
            return .{
                .fd = fd,
                .info = std.mem.bytesToValue(Info, msg.payload[0..@sizeOf(Info)]),
            };
        }
    }
    return error.Unexpected;
}

//  WIRE PROTOCOL FREEZE — read before "fixing" any test below.
//
//  Changing these constants does not fix the test; it breaks every
//  running daemon for every user until they `pkill -f zmx`.
//
//  Need a new field?   → add a new `Tag` value (next free integer).
//  Need to remove one? → don't. Reserve the integer, stop sending it.
test "Info wire size is frozen" {
    try std.testing.expectEqual(@as(usize, 552), @sizeOf(Info));
    // packed struct{u8,u32} backs to u40 → @sizeOf rounds to 8, not 5.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Header));
}

test "Tag wire values are frozen" {
    inline for (.{
        .{ Tag.Input, 0 },  .{ Tag.Output, 1 },        .{ Tag.Resize, 2 },
        .{ Tag.Detach, 3 }, .{ Tag.DetachAll, 4 },     .{ Tag.Kill, 5 },
        .{ Tag.Info, 6 },   .{ Tag.Init, 7 },          .{ Tag.History, 8 },
        .{ Tag.Run, 9 },    .{ Tag.Ack, 10 },          .{ Tag.Switch, 11 },
        .{ Tag.Write, 12 }, .{ Tag.TaskComplete, 13 },
    }) |p| try std.testing.expectEqual(@as(u8, p[1]), @intFromEnum(p[0]));
}

test "zeroed Info has no stack garbage in wire bytes" {
    var info = std.mem.zeroes(Info);
    info.clients_len = 3;
    info.pid = 999;
    info.task_exit_code = 7;
    const bytes = std.mem.asBytes(&info);
    // Tail padding after task_exit_code must be zero (asBytes ships it).
    const last_field_end = @offsetOf(Info, "task_exit_code") + @sizeOf(u8);
    for (bytes[last_field_end..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
