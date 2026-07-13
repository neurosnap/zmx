const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const SessionMatch = @import("root.zig").SessionMatch;
const parseSessionArg = @import("root.zig").parseSessionArg;
const shared = @import("shared.zig");
const util = @import("../util.zig");
const ipc = @import("../ipc.zig");
const socket = @import("../socket.zig");
const root = @import("root.zig");
const posix = std.posix;

fn buildPollList(
    alloc: std.mem.Allocator,
    poll_fds: *std.ArrayList(posix.pollfd),
    client_fds: []const i32,
    has_pending_stdout: bool,
) !void {
    for (client_fds) |fd| {
        try poll_fds.append(alloc, .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 });
    }
    if (has_pending_stdout) {
        try poll_fds.append(alloc, .{ .fd = posix.STDOUT_FILENO, .events = posix.POLL.OUT, .revents = 0 });
    }
}

fn processDaemonMessages(
    read_buf: *ipc.SocketBuffer,
    alloc: std.mem.Allocator,
    stdout_buf: *std.ArrayList(u8),
    is_first_line: *bool,
    task_complete_code: *?u8,
    detached: bool,
    is_run_cmd: bool,
) !?u8 {
    while (read_buf.next()) |msg| {
        switch (msg.header.tag) {
            .Ack => {
                if (!detached) continue;
                _ = posix.write(posix.STDOUT_FILENO, "command sent!\n") catch |err| {
                    if (err == error.WouldBlock) return 0;
                    return err;
                };
                return 0;
            },
            .Output => {
                if (msg.payload.len == 0) continue;
                var payload = msg.payload;
                if (!detached and is_run_cmd and is_first_line.*) {
                    is_first_line.* = false;
                    payload = if (std.mem.indexOfScalar(u8, payload, '\n')) |nl|
                        payload[nl + 1 ..]
                    else
                        payload[payload.len..];
                }
                if (payload.len == 0) continue;
                const plain = util.stripAnsi(alloc, payload) catch |err| {
                    std.log.warn("stripAnsi failed: {s}", .{@errorName(err)});
                    continue;
                };
                defer alloc.free(plain);
                if (plain.len == 0) continue;
                try stdout_buf.appendSlice(alloc, plain);
            },
            .TaskComplete => {
                task_complete_code.* = if (msg.payload.len > 0) msg.payload[0] else 0;
            },
            else => {},
        }
    }
    return null;
}

pub fn tail(client_socket_fds: std.ArrayList(i32), detached: bool, is_run_cmd: bool) !u8 {
    std.debug.assert(client_socket_fds.items.len > 0);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(alloc, shared.initial_poll_capacity);
    defer poll_fds.deinit(alloc);

    var read_buf = try ipc.SocketBuffer.init(alloc);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(alloc, shared.io_buf_size);
    defer stdout_buf.deinit(alloc);

    var is_first_line = true;
    var task_complete_code: ?u8 = null;

    while (true) {
        poll_fds.clearRetainingCapacity();
        std.debug.assert(poll_fds.items.len == 0);

        try buildPollList(alloc, &poll_fds, client_socket_fds.items, stdout_buf.items.len > 0);

        _ = posix.poll(poll_fds.items, -1) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };

        for (poll_fds.items) |*poll_fd| {
            if (poll_fd.revents & posix.POLL.IN == 0) continue;

            const n = read_buf.read(poll_fd.fd) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) return 1;
                std.log.err("daemon read err={s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) return 0;

            const exit_code = try processDaemonMessages(&read_buf, alloc, &stdout_buf, &is_first_line, &task_complete_code, detached, is_run_cmd);
            if (exit_code) |code| return code;
        }

        if (stdout_buf.items.len > 0) {
            const n = posix.write(posix.STDOUT_FILENO, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (task_complete_code) |code| return code;
            if (n > 0) try stdout_buf.replaceRange(alloc, 0, n, &[_]u8{});
        }

        for (poll_fds.items) |poll_fd| {
            if (poll_fd.revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) return 0;
        }
    }
}

pub fn cmdTail(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    var matchers: std.ArrayList(SessionMatch) = .empty;
    defer {
        for (matchers.items) |m| alloc.free(m.name);
        matchers.deinit(alloc);
    }
    while (args.next()) |arg| {
        if (shared.isHelp(arg)) return shared.printUsage("tail", "<name>...");
        try matchers.append(alloc, try parseSessionArg(alloc, arg));
    }
    if (matchers.items.len == 0) return error.SessionNameRequired;

    var resolved_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (resolved_names.items) |name| alloc.free(name);
        resolved_names.deinit(alloc);
    }

    var prefix_matchers: std.ArrayList(SessionMatch) = .empty;
    defer prefix_matchers.deinit(alloc);
    for (matchers.items) |m| {
        if (m.is_prefix) try prefix_matchers.append(alloc, m);
    }

    if (prefix_matchers.items.len > 0) {
        var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
        defer {
            for (sessions.items) |s| s.deinit(alloc);
            sessions.deinit(alloc);
        }
        const matched = try root.collectMatchingSessions(alloc, sessions.items, prefix_matchers.items);
        defer alloc.free(matched);
        for (matched) |name| try resolved_names.append(alloc, name);
    }
    for (matchers.items) |m| {
        if (m.is_prefix) continue;
        try resolved_names.append(alloc, try alloc.dupe(u8, m.name));
    }

    var client_socket_fds = try std.ArrayList(i32).initCapacity(alloc, resolved_names.items.len);
    defer {
        for (client_socket_fds.items) |fd| posix.close(fd);
        client_socket_fds.deinit(alloc);
    }
    for (resolved_names.items) |session_name| {
        const socket_path = socket.getSocketPathChecked(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
            error.NameTooLong => return,
            error.OutOfMemory => |e| return e,
        };
        try client_socket_fds.append(alloc, try socket.sessionConnect(socket_path));
    }
    _ = try tail(client_socket_fds, false, false);
}
