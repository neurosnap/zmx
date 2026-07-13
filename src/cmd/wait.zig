const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const SessionMatch = @import("root.zig").SessionMatch;
const parseSessionArg = @import("root.zig").parseSessionArg;
const shared = @import("shared.zig");
const util = @import("../util.zig");
const ipc = @import("../ipc.zig");
const socket = @import("../socket.zig");

fn wait(cfg: *Cfg, matchers: std.ArrayList(SessionMatch)) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    var max_seen: i32 = 0;
    var zero_match_iters: u32 = 0;

    var agg_exit_code: u8 = 0;
    var last_print: i64 = 0;
    var prev_done: i32 = 0;
    while (true) {
        agg_exit_code = 0;
        var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
        var total: i32 = 0;
        var done: i32 = 0;

        for (sessions.items) |session| {
            var found = false;
            for (matchers.items) |m| {
                if (m.matches(session.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;

            total += 1;
            if (session.is_error) {
                try stderr.print("[{d}] task unreachable: {s} ({s})\n", .{ std.time.timestamp(), session.name, session.error_name orelse "unknown" });
                try stderr.flush();
                agg_exit_code = 1;
                done += 1;
                continue;
            }
            if (session.task_ended_at == 0) {
                const now = std.time.timestamp();
                if (now - last_print >= 5) {
                    try stdout.print("[{d}] waiting task={s}\n", .{ now, session.name });
                    try stdout.flush();
                    last_print = now;
                }
                continue;
            }
            if (done >= prev_done) {
                try stdout.print("[{d}] completed task={s} exit_code={d}\n", .{ session.task_ended_at.?, session.name, session.task_exit_code.? });
                try stdout.flush();
            }
            if (session.task_exit_code != 0) {
                agg_exit_code = session.task_exit_code orelse 0;
            }
            done += 1;
        }

        for (sessions.items) |session| {
            session.deinit(alloc);
        }
        sessions.deinit(alloc);

        if (total < max_seen) {
            try stderr.print("error: {d} session(s) disappeared before completing\n", .{max_seen - total});
            try stderr.flush();
            std.process.exit(1);
        }
        max_seen = total;

        if (total > 0 and total == done) break;

        if (max_seen == 0) {
            zero_match_iters += 1;
            if (zero_match_iters >= 3) {
                try stderr.print("error: no matching sessions found\n", .{});
                try stderr.flush();
                std.process.exit(2);
            }
        }

        prev_done = done;
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }

    if (agg_exit_code == 0) {
        try stdout.print("task(s) completed!\n", .{});
    } else {
        try stdout.print("task(s) failed!\n", .{});
    }
    try stdout.flush();

    // Reprint detailed failure info for failed sessions
    const sessions2 = try util.get_session_entries(alloc, cfg.socket_dir);
    for (sessions2.items) |session| {
        var found = false;
        for (matchers.items) |m| {
            if (m.matches(session.name)) {
                found = true;
                break;
            }
        }
        if (!found) continue;
        if (session.task_exit_code.? > 0) {
            try stdout.print("---\n", .{});
            try stdout.print("[{d}] failed task={s} exit_status={d}\n", .{ session.task_ended_at.?, session.name, session.task_exit_code.? });

            const history_lines: usize = 20;
            const history_text = fetchHistory(alloc, cfg, session.name) catch null;
            if (history_text) |text| {
                defer alloc.free(text);
                try stdout.print("\nLast {d} lines of {s} history:\n", .{ history_lines, session.name });

                var total_lines: usize = 0;
                var it = std.mem.splitScalar(u8, text, '\n');
                while (it.next()) |_| total_lines += 1;

                const skip = if (total_lines > history_lines) total_lines - history_lines else 0;
                var current: usize = 0;
                it = std.mem.splitScalar(u8, text, '\n');
                while (it.next()) |line| {
                    if (current >= skip) {
                        try stdout.print("{s}\n", .{line});
                    }
                    current += 1;
                }
            }
            try stdout.print("\nSee the logs:\nzmx history {s}\nzmx attach {s}\n", .{ session.name, session.name });
            try stdout.flush();
        }
    }

    std.process.exit(agg_exit_code);
}

fn fetchHistory(alloc: std.mem.Allocator, cfg: *Cfg, session_name: []const u8) ![]const u8 {
    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => {
            socket.printSessionNameTooLong(session_name, cfg.socket_dir);
            return error.NameTooLong;
        },
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, session_name);
    if (!exists) return error.SessionNotFound;

    const fd = ipc.connectSession(socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return err;
    };
    defer std.posix.close(fd);

    const format_byte: u8 = @intFromEnum(util.HistoryFormat.plain);
    const payload = [_]u8{format_byte};
    ipc.send(fd, .History, &payload) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return error.SessionUnresponsive,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    var result = std.ArrayList(u8).initCapacity(alloc, 4096) catch return error.OutOfMemory;
    errdefer result.deinit(alloc);

    while (true) {
        var poll_fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const poll_result = std.posix.poll(&poll_fds, 5000) catch return error.Timeout;
        if (poll_result == 0) return error.Timeout;

        const n = sb.read(fd) catch return error.ReadFailed;
        if (n == 0) break;

        while (sb.next()) |msg| {
            if (msg.header.tag == .History) {
                try result.appendSlice(alloc, msg.payload);
                return result.toOwnedSlice(alloc);
            }
        }
    }
    return error.NoHistoryResponse;
}

pub fn cmdWait(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    var matchers: std.ArrayList(SessionMatch) = .empty;
    defer {
        for (matchers.items) |m| alloc.free(m.name);
        matchers.deinit(alloc);
    }
    while (args.next()) |arg| {
        if (shared.isHelp(arg)) return shared.printUsage("wait", "<name>...");
        try matchers.append(alloc, try parseSessionArg(alloc, arg));
    }
    if (matchers.items.len == 0) return error.SessionNameRequired;
    return wait(cfg, matchers);
}
