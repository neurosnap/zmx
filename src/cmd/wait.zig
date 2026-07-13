const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const SessionMatch = @import("root.zig").SessionMatch;
const parseSessionArg = @import("root.zig").parseSessionArg;
const shared = @import("shared.zig");
const util = @import("../util.zig");

const STATUS_PRINT_INTERVAL_SECS = 5;
const MAX_ZERO_MATCH_ITERATIONS = 3;
const POLL_SLEEP_MS = 1000;
const HISTORY_PREVIEW_LINES = 20;

fn wait(cfg: *Cfg, matchers: std.ArrayList(SessionMatch)) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdout_buffer: [shared.io_buf_size]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [shared.io_buf_size]u8 = undefined;
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
                if (now - last_print >= STATUS_PRINT_INTERVAL_SECS) {
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
            if (zero_match_iters >= MAX_ZERO_MATCH_ITERATIONS) {
                try stderr.print("error: no matching sessions found\n", .{});
                try stderr.flush();
                std.process.exit(2);
            }
        }

        prev_done = done;
        std.Thread.sleep(POLL_SLEEP_MS * std.time.ns_per_ms);
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

            const history_text = shared.fetchHistory(alloc, cfg, session.name) catch null;
            if (history_text) |text| {
                defer alloc.free(text);
                try stdout.print("\nLast {d} lines of {s} history:\n", .{ HISTORY_PREVIEW_LINES, session.name });

                var total_lines: usize = 0;
                var it = std.mem.splitScalar(u8, text, '\n');
                while (it.next()) |_| total_lines += 1;

                const skip = if (total_lines > HISTORY_PREVIEW_LINES) total_lines - HISTORY_PREVIEW_LINES else 0;
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
