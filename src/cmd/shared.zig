const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const log = @import("../log.zig");
const ipc = @import("../ipc.zig");
const socket = @import("../socket.zig");

pub var log_system = log.LogSystem{};

pub const io_buf_size = 4096;
pub const initial_poll_capacity = 8;
pub const initial_client_capacity = 10;

pub const O_NONBLOCK: usize = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");

pub var sig_pipe: [2]std.posix.fd_t = .{ -1, -1 };

pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn openSignalPipe() !void {
    sig_pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
}

pub fn drainSignalPipe() void {
    var b: [16]u8 = undefined;
    while (true) {
        const n = std.posix.read(sig_pipe[0], &b) catch return;
        if (n == 0) return;
    }
}

fn wakeSignalPipe(_: i32, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = std.c._errno().*;
    _ = std.c.write(sig_pipe[1], "x", 1);
    std.c._errno().* = saved;
}

pub fn installWakeHandler(sig: u6) void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = wakeSignalPipe },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO,
    };
    std.posix.sigaction(sig, &act, null);
}

pub fn ignoreSigpipe() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
}

pub fn setNonblocking(fd: i32) !usize {
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | O_NONBLOCK);
    return flags;
}

pub fn printUsage(cmd_name: []const u8, usage: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print("Usage: zmx {s} {s}\n", .{ cmd_name, usage });
    try w.interface.flush();
}

pub fn fetchHistory(alloc: std.mem.Allocator, cfg: *Cfg, session_name: []const u8) ![]const u8 {
    const socket_path = try socket.getSocketPathChecked(alloc, cfg.socket_dir, session_name);
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    if (!try socket.sessionExists(dir, session_name)) return error.SessionNotFound;

    const fd = ipc.connectSession(socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return err;
    };
    defer std.posix.close(fd);

    const payload = [_]u8{0}; // HistoryFormat.plain
    ipc.send(fd, .History, &payload) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return error.SessionUnresponsive,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    var result = std.ArrayList(u8).initCapacity(alloc, ipc.socket_buffer_size) catch return error.OutOfMemory;
    errdefer result.deinit(alloc);

    while (true) {
        var poll_fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const poll_result = std.posix.poll(&poll_fds, ipc.history_poll_timeout_ms) catch return error.Timeout;
        if (poll_result == 0) return error.Timeout;

        const n = sb.read(fd) catch return error.ReadFailed;
        if (n == 0) break;

        while (sb.next()) |msg| {
            if (msg.header.tag == .History) {
                try result.appendSlice(alloc, msg.payload);
                return result.toOwnedSlice(alloc);
            }
        }
    }
    return error.NoHistoryResponse;
}
