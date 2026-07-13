const std = @import("std");
const posix = std.posix;
const Cfg = @import("../Cfg.zig").Cfg;
const shared = @import("shared.zig");
const ipc = @import("../ipc.zig");
const socket = @import("../socket.zig");
const daemon_mod = @import("daemon.zig");
const ClientMod = @import("../Client.zig");

const Client = ClientMod.Client;
const Daemon = daemon_mod.Daemon;

fn writeFile(daemon: *Daemon, file_path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const sesh_result = try daemon.ensureSession();
    if (sesh_result.is_daemon) return;

    if (sesh_result.created) {
        try w.interface.print("session \"{s}\" created\n", .{daemon.session_name});
        try w.interface.flush();
    }
    const stdin_fd = posix.STDIN_FILENO;
    var stdin_buf = try std.ArrayList(u8).initCapacity(daemon.alloc, 4096);
    defer stdin_buf.deinit(daemon.alloc);

    while (true) {
        var tmp: [4096]u8 = undefined;
        const n = posix.read(stdin_fd, &tmp) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
        if (n == 0) break;
        try stdin_buf.appendSlice(daemon.alloc, tmp[0..n]);
    }

    const socket_path = socket.getSocketPath(daemon.alloc, daemon.cfg.socket_dir, daemon.session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(daemon.session_name, daemon.cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    var dir = try std.fs.openDirAbsolute(daemon.cfg.socket_dir, .{});
    defer dir.close();

    const result = ipc.probeSession(daemon.alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(dir, daemon.session_name);
            w.interface.print("cleaned up stale session {s}\n", .{daemon.session_name}) catch {};
        } else {
            w.interface.print("session {s} is unresponsive ({s})\ndaemon may be busy: try again\n", .{ daemon.session_name, @errorName(err) }) catch {};
        }
        w.interface.flush() catch {};
        return;
    };

    defer posix.close(result.fd);

    var wire_buf = try std.ArrayList(u8).initCapacity(daemon.alloc, @sizeOf(u32) + file_path.len + stdin_buf.items.len);
    defer wire_buf.deinit(daemon.alloc);
    const path_len: u32 = @intCast(file_path.len);
    try wire_buf.appendSlice(daemon.alloc, std.mem.asBytes(&path_len));
    try wire_buf.appendSlice(daemon.alloc, file_path);
    try wire_buf.appendSlice(daemon.alloc, stdin_buf.items);

    ipc.send(result.fd, .Write, wire_buf.items) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(daemon.alloc);
    defer sb.deinit();

    const n = sb.read(result.fd) catch return error.ReadFailed;
    if (n == 0) return error.ConnectionClosed;

    while (sb.next()) |msg| {
        if (msg.header.tag == .Ack) {
            try w.interface.print("file created {s}\n", .{file_path});
            try w.interface.flush();
            return;
        }
    }

    return error.NoAckReceived;
}

pub fn cmdWrite(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const session_name = args.next() orelse "";
    if (shared.isHelp(session_name)) return shared.printUsage("write", "<name> <file_path>");
    if (session_name.len == 0) return error.SessionNameRequired;
    const file_path = args.next() orelse "";
    if (shared.isHelp(file_path)) return shared.printUsage("write", "<name> <file_path>");
    if (file_path.len == 0) return error.FilePathRequired;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";
    const clients = try std.ArrayList(*Client).initCapacity(alloc, 10);
    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    var d = Daemon{
        .running = true,
        .cfg = cfg,
        .alloc = alloc,
        .clients = clients,
        .session_name = sesh,
        .socket_path = undefined,
        .pid = undefined,
        .command = null,
        .cwd = cwd,
        .created_at = @intCast(std.time.timestamp()),
        .is_task_mode = true,
        .leader_client_fd = null,
    };
    d.socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    std.log.info("socket path={s}", .{d.socket_path});
    try writeFile(&d, file_path);
}
