const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const shared = @import("shared.zig");
const util = @import("../util.zig");
const socket = @import("../socket.zig");

fn list(cfg: *Cfg, short: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const current_session = socket.getSeshNameFromEnv();
    var buf: [shared.io_buf_size]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
    defer {
        for (sessions.items) |session| {
            session.deinit(alloc);
        }
        sessions.deinit(alloc);
    }

    if (sessions.items.len == 0) {
        if (short) return;
        try shared.printErr("no sessions found in {s}\n", .{cfg.socket_dir});
        return;
    }

    std.mem.sort(util.SessionEntry, sessions.items, {}, util.SessionEntry.lessThan);

    for (sessions.items) |session| {
        try util.writeSessionLine(&stdout.interface, session, short, current_session);
        try stdout.interface.flush();
    }
}

pub fn cmdList(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    _ = alloc;
    var short = false;
    if (args.next()) |arg| {
        if (shared.isHelp(arg)) return shared.printUsage("list", "[--short]");
        short = std.mem.eql(u8, arg, "--short");
    }
    return list(cfg, short);
}
