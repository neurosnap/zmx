const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const SessionMatch = @import("root.zig").SessionMatch;
const parseSessionArg = @import("root.zig").parseSessionArg;
const collectMatchingSessions = @import("root.zig").collectMatchingSessions;
const shared = @import("shared.zig");
const util = @import("../util.zig");
const ipc = @import("../ipc.zig");
const socket = @import("../socket.zig");

fn kill(cfg: *Cfg, session_name: []const u8, force: bool) !void {
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
        var buf: [shared.io_buf_size]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        if (force or err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(dir, session_name);
            w.interface.print("cleaned up stale session {s}\n", .{session_name}) catch {};
        } else {
            w.interface.print(
                "session {s} is unresponsive ({s})\ndaemon may be busy: try again, add `--force` flag, or kill the process directly\n",
                .{ session_name, @errorName(err) },
            ) catch {};
        }
        w.interface.flush() catch {};
        return;
    };

    defer std.posix.close(fd);
    ipc.send(fd, .Kill, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var buf: [shared.io_buf_size]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("killed session {s}\n", .{session_name});
    try w.interface.flush();
}

pub fn cmdKill(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    var stderr_buffer: [shared.io_buf_size]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    var matchers: std.ArrayList(SessionMatch) = .empty;
    defer {
        for (matchers.items) |m| alloc.free(m.name);
        matchers.deinit(alloc);
    }
    var force = false;
    while (args.next()) |arg| {
        if (shared.isHelp(arg)) return shared.printUsage("kill", "<name>... [--force]");
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
            continue;
        }
        try matchers.append(alloc, try parseSessionArg(alloc, arg));
    }
    if (matchers.items.len == 0) return error.SessionNameRequired;

    var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
    defer {
        for (sessions.items) |session| session.deinit(alloc);
        sessions.deinit(alloc);
    }
    const matched = try collectMatchingSessions(alloc, sessions.items, matchers.items);
    defer {
        for (matched) |name| alloc.free(name);
        alloc.free(matched);
    }
    for (matched) |name| {
        kill(cfg, name, force) catch |err| {
            try stderr.print("failed to kill session={s}: {s}\n", .{ name, @errorName(err) });
            try stderr.flush();
        };
    }
}
