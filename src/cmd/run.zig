const std = @import("std");
const posix = std.posix;
const Cfg = @import("../cfg.zig").Cfg;
const shared = @import("shared.zig");
const ipc = @import("../ipc.zig");
const socket = @import("../socket.zig");
const util = @import("../util.zig");
const daemon_mod = @import("daemon.zig");
const tail = @import("tail.zig");

const Daemon = daemon_mod.Daemon;

fn run(daemon: *Daemon, detached: bool, command_args: [][]const u8) !void {
    const alloc = daemon.alloc;

    var cmd_to_send: ?[]const u8 = null;
    var allocated_cmd: ?[]u8 = null;
    defer if (allocated_cmd) |cmd| alloc.free(cmd);

    const result = try daemon.ensureSession();
    if (result.is_daemon) return;

    if (result.created) {
        try shared.printOut("session \"{s}\" created\n", .{daemon.session_name});
    }

    if (command_args.len > 0) {
        var cmd_list = std.ArrayList(u8).empty;
        defer cmd_list.deinit(alloc);

        for (command_args, 0..) |arg, i| {
            if (i > 0) try cmd_list.append(alloc, ' ');
            if (util.shellNeedsQuoting(arg)) {
                const quoted = try util.shellQuote(alloc, arg);
                defer alloc.free(quoted);
                try cmd_list.appendSlice(alloc, quoted);
            } else {
                try cmd_list.appendSlice(alloc, arg);
            }
        }

        try cmd_list.append(alloc, '\r');

        cmd_to_send = try cmd_list.toOwnedSlice(alloc);
        allocated_cmd = @constCast(cmd_to_send.?);
    } else {
        const stdin_fd = posix.STDIN_FILENO;
        if (!std.posix.isatty(stdin_fd)) {
            var stdin_buf = try std.ArrayList(u8).initCapacity(alloc, shared.io_buf_size);
            defer stdin_buf.deinit(alloc);

            while (true) {
                var tmp: [shared.io_buf_size]u8 = undefined;
                const n = posix.read(stdin_fd, &tmp) catch |err| {
                    if (err == error.WouldBlock) break;
                    return err;
                };
                if (n == 0) break;
                try stdin_buf.appendSlice(alloc, tmp[0..n]);
            }

            if (stdin_buf.items.len > 0) {
                if (stdin_buf.items[stdin_buf.items.len - 1] == '\n') {
                    stdin_buf.items[stdin_buf.items.len - 1] = '\r';
                } else {
                    try stdin_buf.append(alloc, '\r');
                }

                cmd_to_send = try alloc.dupe(u8, stdin_buf.items);
                allocated_cmd = @constCast(cmd_to_send.?);
            }
        }
    }

    if (cmd_to_send == null) return error.CommandRequired;

    const client_sock = ipc.connectSession(daemon.socket_path) catch |err| {
        std.log.err("session not ready: {s}", .{@errorName(err)});
        return error.SessionNotReady;
    };
    defer posix.close(client_sock);

    var fds = try std.ArrayList(i32).initCapacity(alloc, 1);
    defer fds.deinit(alloc);
    try fds.append(alloc, client_sock);

    ipc.send(client_sock, .Run, cmd_to_send.?) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };

    const exit_code = try tail.tail(fds, detached, true);
    posix.exit(exit_code);
}

pub fn cmdRun(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const session_name = args.next() orelse "";
    if (shared.isHelp(session_name)) return shared.printUsage("run", "<name> [-d] [command...]");

    var cmd_args_raw: std.ArrayList([]const u8) = .empty;
    defer cmd_args_raw.deinit(alloc);
    var detached = false;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-d")) {
            detached = true;
            continue;
        }
        try cmd_args_raw.append(alloc, arg);
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";

    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    var d = try Daemon.init(alloc, cfg, sesh, null, cwd);
    d.is_task_mode = true;
    std.log.info("socket path={s}", .{d.socket_path});
    return run(&d, detached, cmd_args_raw.items);
}
