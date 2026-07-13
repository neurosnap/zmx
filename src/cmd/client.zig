const std = @import("std");
const posix = std.posix;
const ipc = @import("../ipc.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");

pub const ClientResult = struct {
    kind: enum {
        detach,
        switch_session,
    },
    session_name: ?[]const u8,
};

fn fillPollFds(
    alloc: std.mem.Allocator,
    poll_fds: *std.ArrayList(posix.pollfd),
    client_sock_fd: i32,
    sock_write_buf: []const u8,
    stdout_buf: []const u8,
) !void {
    poll_fds.clearRetainingCapacity();
    try poll_fds.append(alloc, .{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    var sock_events: i16 = posix.POLL.IN;
    if (sock_write_buf.len > 0) sock_events |= posix.POLL.OUT;
    try poll_fds.append(alloc, .{ .fd = client_sock_fd, .events = sock_events, .revents = 0 });
    try poll_fds.append(alloc, .{ .fd = shared.sig_pipe[0], .events = posix.POLL.IN, .revents = 0 });

    if (stdout_buf.len > 0) {
        try poll_fds.append(alloc, .{
            .fd = posix.STDOUT_FILENO,
            .events = posix.POLL.OUT,
            .revents = 0,
        });
    }
}

fn handleSigEvent(alloc: std.mem.Allocator, sock_write_buf: *std.ArrayList(u8), revents: i16) !void {
    if (revents & posix.POLL.IN == 0) return;
    shared.drainSignalPipe();
    const next_size = ipc.getTerminalSize(posix.STDOUT_FILENO);
    try ipc.appendMessage(alloc, sock_write_buf, .Resize, std.mem.asBytes(&next_size));
}

fn handleStdinEvent(
    alloc: std.mem.Allocator,
    sock_write_buf: *std.ArrayList(u8),
    revents: i16,
) !?ClientResult {
    const inp_flags = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;
    if (revents & inp_flags == 0) return null;

    var buf: [shared.io_buf_size]u8 = undefined;
    const n_opt: ?usize = posix.read(posix.STDIN_FILENO, &buf) catch |err| {
        if (err == error.WouldBlock) return null;
        return err;
    };
    const n = n_opt orelse return null;
    if (n == 0) return ClientResult{ .kind = .detach, .session_name = null };

    const tag: ipc.Tag = if (util.isCtrlBackslash(buf[0..n])) .Detach else .Input;
    try ipc.appendMessage(
        alloc,
        sock_write_buf,
        tag,
        if (tag == .Detach) "" else buf[0..n],
    );
    return null;
}

fn handleDaemonEvent(
    alloc: std.mem.Allocator,
    client_sock_fd: i32,
    read_buf: *ipc.SocketBuffer,
    sock_write_buf: *std.ArrayList(u8),
    stdout_buf: *std.ArrayList(u8),
    revents: i16,
) !?ClientResult {
    if (revents & posix.POLL.IN == 0) return null;

    const n = read_buf.read(client_sock_fd) catch |err| {
        if (err == error.WouldBlock) return null;
        if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
            return ClientResult{ .kind = .detach, .session_name = null };
        }
        std.log.err("daemon read err={s}", .{@errorName(err)});
        return err;
    };
    if (n == 0) return ClientResult{ .kind = .detach, .session_name = null };

    while (read_buf.next()) |msg| {
        switch (msg.header.tag) {
            .Output => {
                if (msg.payload.len > 0) try stdout_buf.appendSlice(alloc, msg.payload);
            },
            .Resize => {
                const next_size = ipc.getTerminalSize(posix.STDOUT_FILENO);
                try ipc.appendMessage(alloc, sock_write_buf, .Resize, std.mem.asBytes(&next_size));
            },
            .Switch => {
                return ClientResult{
                    .kind = .switch_session,
                    .session_name = try alloc.dupe(u8, msg.payload),
                };
            },
            else => {},
        }
    }
    return null;
}

fn flushSocketBuf(
    alloc: std.mem.Allocator,
    client_sock_fd: i32,
    sock_write_buf: *std.ArrayList(u8),
    revents: i16,
) !?ClientResult {
    if (revents & posix.POLL.OUT == 0 or sock_write_buf.items.len == 0) return null;

    const n = posix.write(client_sock_fd, sock_write_buf.items) catch |err| {
        if (err == error.WouldBlock) return null;
        if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
            return ClientResult{ .kind = .detach, .session_name = null };
        }
        return err;
    };
    if (n > 0) try sock_write_buf.replaceRange(alloc, 0, n, &[_]u8{});
    return null;
}

fn flushTerminal(alloc: std.mem.Allocator, stdout_buf: *std.ArrayList(u8)) !void {
    if (stdout_buf.items.len == 0) return;

    const n = posix.write(posix.STDOUT_FILENO, stdout_buf.items) catch |err| {
        if (err == error.WouldBlock) return;
        return err;
    };
    if (n > 0) try stdout_buf.replaceRange(alloc, 0, n, &[_]u8{});
}

pub fn clientLoop(client_sock_fd: i32) !ClientResult {
    const alloc = std.heap.c_allocator;
    defer posix.close(client_sock_fd);

    try shared.openSignalPipe();
    shared.installWakeHandler(posix.SIG.WINCH);

    _ = try shared.setNonblocking(client_sock_fd);
    const stdin_orig_flags = try shared.setNonblocking(posix.STDIN_FILENO);
    defer _ = posix.fcntl(posix.STDIN_FILENO, posix.F.SETFL, stdin_orig_flags) catch {};

    var sock_write_buf = try std.ArrayList(u8).initCapacity(alloc, shared.io_buf_size);
    defer sock_write_buf.deinit(alloc);

    var stdout_buf = try std.ArrayList(u8).initCapacity(alloc, shared.io_buf_size);
    defer stdout_buf.deinit(alloc);

    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(alloc, shared.initial_poll_capacity);
    defer poll_fds.deinit(alloc);

    var read_buf = try ipc.SocketBuffer.init(alloc);
    defer read_buf.deinit();

    const size = ipc.getTerminalSize(posix.STDOUT_FILENO);
    try ipc.appendMessage(alloc, &sock_write_buf, .Init, std.mem.asBytes(&size));

    std.debug.assert(client_sock_fd >= 0);
    std.debug.assert(shared.sig_pipe[0] >= 0);

    while (true) {
        try fillPollFds(alloc, &poll_fds, client_sock_fd, sock_write_buf.items, stdout_buf.items);
        _ = try posix.poll(poll_fds.items, -1);

        try handleSigEvent(alloc, &sock_write_buf, poll_fds.items[2].revents);

        if (try handleStdinEvent(alloc, &sock_write_buf, poll_fds.items[0].revents)) |r| return r;
        if (try handleDaemonEvent(alloc, client_sock_fd, &read_buf, &sock_write_buf, &stdout_buf, poll_fds.items[1].revents)) |r| return r;
        if (try flushSocketBuf(alloc, client_sock_fd, &sock_write_buf, poll_fds.items[1].revents)) |r| return r;

        try flushTerminal(alloc, &stdout_buf);

        const err_events = posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;
        if (poll_fds.items[1].revents & err_events != 0) {
            return ClientResult{ .kind = .detach, .session_name = null };
        }
    }
}
