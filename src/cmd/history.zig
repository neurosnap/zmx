const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const shared = @import("shared.zig");
const util = @import("../util.zig");
const ipc = @import("../ipc.zig");
const socket = @import("../socket.zig");

fn history(cfg: *Cfg, session_name: []const u8, format: util.HistoryFormat) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const socket_path = socket.getSocketPathChecked(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return,
        error.OutOfMemory => |e| return e,
    };
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, session_name);
    if (!exists) {
        var buf: [shared.io_buf_size]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        w.interface.print("error: session \"{s}\" does not exist\n", .{session_name}) catch {};
        w.interface.flush() catch {};
        return error.SessionNotFound;
    }
    const fd = ipc.connectSession(socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return;
    };
    defer std.posix.close(fd);

    const format_byte = [_]u8{@intFromEnum(format)};
    ipc.send(fd, .History, &format_byte) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    while (true) {
        var poll_fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const poll_result = std.posix.poll(&poll_fds, ipc.history_poll_timeout_ms) catch return;
        if (poll_result == 0) {
            std.log.err("timeout waiting for history response", .{});
            return;
        }

        const n = sb.read(fd) catch return;
        if (n == 0) return;

        while (sb.next()) |msg| {
            if (msg.header.tag == .History) {
                _ = std.posix.write(std.posix.STDOUT_FILENO, msg.payload) catch return;
                return;
            }
        }
    }
}

pub fn cmdHistory(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    var session_name: ?[]const u8 = null;
    var format: util.HistoryFormat = .plain;
    while (args.next()) |arg| {
        if (shared.isHelp(arg)) return shared.printUsage("history", "<name> [--vt|--html]");
        if (std.mem.eql(u8, arg, "--vt")) {
            format = .vt;
        } else if (std.mem.eql(u8, arg, "--html")) {
            format = .html;
        } else if (session_name == null) {
            session_name = arg;
        }
    }
    const sesh_env = socket.getSeshNameFromEnv();
    const sesh = try socket.getSeshName(alloc, session_name orelse sesh_env);
    defer alloc.free(sesh);
    return history(cfg, sesh, format);
}
