const std = @import("std");
const posix = std.posix;
const Cfg = @import("../Cfg.zig").Cfg;
const shared = @import("shared.zig");
const ipc = @import("../ipc.zig");
const socket = @import("../socket.zig");
const daemon_mod = @import("daemon.zig");

const Daemon = daemon_mod.Daemon;

fn writeFile(daemon: *Daemon, file_path: []const u8) !void {
    const sesh_result = try daemon.ensureSession();
    if (sesh_result.is_daemon) return;

    if (sesh_result.created) {
        try shared.printOut("session \"{s}\" created\n", .{daemon.session_name});
    }
    const stdin_fd = posix.STDIN_FILENO;
    var stdin_buf = try std.ArrayList(u8).initCapacity(daemon.alloc, shared.io_buf_size);
    defer stdin_buf.deinit(daemon.alloc);

    while (true) {
        var tmp: [shared.io_buf_size]u8 = undefined;
        const n = posix.read(stdin_fd, &tmp) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
        if (n == 0) break;
        try stdin_buf.appendSlice(daemon.alloc, tmp[0..n]);
    }

    const socket_path = socket.getSocketPathChecked(daemon.alloc, daemon.cfg.socket_dir, daemon.session_name) catch |err| switch (err) {
        error.NameTooLong => return,
        error.OutOfMemory => |e| return e,
    };

    const result = shared.probeSessionChecked(daemon.alloc, daemon.cfg.socket_dir, daemon.session_name, socket_path) catch {
        shared.printOut("session {s} is unresponsive\ndaemon may be busy: try again\n", .{daemon.session_name}) catch {};
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
            try shared.printOut("file created {s}\n", .{file_path});
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
    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    var d = try Daemon.init(alloc, cfg, sesh, null, cwd);
    d.is_task_mode = true;
    std.log.info("socket path={s}", .{d.socket_path});
    try writeFile(&d, file_path);
}
