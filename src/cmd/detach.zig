const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const ipc = @import("../ipc.zig");
const socket = @import("../socket.zig");

fn detachAll(cfg: *Cfg) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const session_name = socket.getSeshNameFromEnv();
    if (session_name.len == 0) {
        std.log.err("ZMX_SESSION env var not found: are you inside a zmx session?", .{});
        return;
    }

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const socket_path = socket.getSocketPathChecked(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return,
        error.OutOfMemory => |e| return e,
    };
    defer alloc.free(socket_path);
    const fd = ipc.connectSession(socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return;
    };
    defer std.posix.close(fd);
    ipc.send(fd, .DetachAll, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

pub fn cmdDetach(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    _ = alloc;
    _ = args;
    return detachAll(cfg);
}
