const std = @import("std");
const Cfg = @import("../cfg.zig").Cfg;
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

    const conn = shared.connectToSessionChecked(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.SessionNotFound => {
            shared.printErr("error: session \"{s}\" does not exist\n", .{session_name}) catch {};
            return error.SessionNotFound;
        },
        error.ConnectionFailed => {
            if (force) {
                var dir = std.fs.openDirAbsolute(cfg.socket_dir, .{}) catch return;
                defer dir.close();
                socket.cleanupStaleSocket(dir, session_name);
            }
            if (force) {
                try shared.printOut("cleaned up stale session {s}\n", .{session_name});
            } else {
                try shared.printOut("session {s} is unresponsive\ndaemon may be busy: try again, add `--force` flag, or kill the process directly\n", .{session_name});
            }
            return;
        },
    };
    defer conn.deinit();
    ipc.send(conn.fd, .Kill, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    try shared.printOut("killed session {s}\n", .{session_name});
}

pub fn cmdKill(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
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
            shared.printErr("failed to kill session={s}: {s}\n", .{ name, @errorName(err) }) catch {};
        };
    }
}
