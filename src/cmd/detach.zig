const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const shared = @import("shared.zig");
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

    const conn = shared.connectToSessionChecked(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.SessionNotFound => return,
        error.ConnectionFailed => return,
    };
    defer conn.deinit();
    ipc.send(conn.fd, .DetachAll, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

pub fn cmdDetach(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    _ = alloc;
    _ = args;
    return detachAll(cfg);
}
