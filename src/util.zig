const std = @import("std");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const socket = @import("socket.zig");

pub const SessionEntry = struct {
    name: []const u8,
    pid: ?i32,
    clients_len: ?usize,
    is_error: bool,
    error_name: ?[]const u8,
    cmd: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    created_at: u64,
    task_ended_at: ?u64,
    task_exit_code: ?u8,

    pub fn deinit(self: SessionEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        if (self.cmd) |cmd| alloc.free(cmd);
        if (self.cwd) |cwd| alloc.free(cwd);
    }

    pub fn lessThan(_: void, a: SessionEntry, b: SessionEntry) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

pub fn get_session_entries(alloc: std.mem.Allocator, socket_dir: []const u8) !std.ArrayList(SessionEntry) {
    var dir = try std.fs.openDirAbsolute(socket_dir, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();

    var sessions = try std.ArrayList(SessionEntry).initCapacity(alloc, 30);

    while (try iter.next()) |entry| {
        const exists = socket.sessionExists(dir, entry.name) catch continue;
        if (exists) {
            const name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(name);

            const socket_path = try socket.getSocketPath(alloc, socket_dir, entry.name);
            defer alloc.free(socket_path);

            const result = ipc.probeSession(alloc, socket_path) catch |err| {
                try sessions.append(alloc, .{
                    .name = name,
                    .pid = null,
                    .clients_len = null,
                    .is_error = true,
                    .error_name = @errorName(err),
                    .created_at = 0,
                    .task_exit_code = 1,
                    .task_ended_at = 0,
                });
                socket.cleanupStaleSocket(dir, entry.name);
                continue;
            };
            posix.close(result.fd);

            // Extract cmd and cwd from the fixed-size arrays
            const cmd: ?[]const u8 = if (result.info.cmd_len > 0)
                alloc.dupe(u8, result.info.cmd[0..result.info.cmd_len]) catch null
            else
                null;
            const cwd: ?[]const u8 = if (result.info.cwd_len > 0)
                alloc.dupe(u8, result.info.cwd[0..result.info.cwd_len]) catch null
            else
                null;

            try sessions.append(alloc, .{
                .name = name,
                .pid = result.info.pid,
                .clients_len = result.info.clients_len,
                .is_error = false,
                .error_name = null,
                .cmd = cmd,
                .cwd = cwd,
                .created_at = result.info.created_at,
                .task_ended_at = result.info.task_ended_at,
                .task_exit_code = result.info.task_exit_code,
            });
        }
    }

    return sessions;
}

pub fn shellNeedsQuoting(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |ch| {
        switch (ch) {
            ' ', '\t', '"', '\'', '\\', '$', '`', '!', '(', ')', '{', '}', '[', ']', '|', '&', ';', '<', '>', '?', '*', '~', '#', '\n' => return true,
            else => {},
        }
    }
    return false;
}

pub fn shellQuote(alloc: std.mem.Allocator, arg: []const u8) ![]u8 {
    // Always use single quotes (like Python's shlex.quote). Inside single
    // quotes nothing is special except ' itself, which we handle with the
    // '\'' trick (end quote, escaped literal quote, reopen quote).
    var len: usize = 2;
    for (arg) |ch| {
        len += if (ch == '\'') 4 else 1;
    }
    const buf = try alloc.alloc(u8, len);
    var i: usize = 0;
    buf[i] = '\'';
    i += 1;
    for (arg) |ch| {
        if (ch == '\'') {
            @memcpy(buf[i..][0..4], "'\\''");
            i += 4;
        } else {
            buf[i] = ch;
            i += 1;
        }
    }
    buf[i] = '\'';
    return buf;
}

const DA1_QUERY = "\x1b[c";
const DA1_QUERY_EXPLICIT = "\x1b[0c";
const DA2_QUERY = "\x1b[>c";
const DA2_QUERY_EXPLICIT = "\x1b[>0c";
const DA1_RESPONSE = "\x1b[?62;22c";
const DA2_RESPONSE = "\x1b[>1;10;0c";

pub fn respondToDeviceAttributes(pty_fd: i32, data: []const u8) void {
    // Scan for DA queries in PTY output and respond on behalf of the terminal.
    // This handles the case where no client is attached (e.g. zmx run)
    // and the shell (e.g. fish) sends a DA query that would otherwise go unanswered.
    //
    // DA1 query: ESC [ c  or  ESC [ 0 c
    // DA2 query: ESC [ > c  or  ESC [ > 0 c
    // DA1 response (from terminal): ESC [ ? ... c  (has '?' after '[')
    //
    // We must NOT match DA responses (which contain '?') as queries.
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == '\x1b' and i + 1 < data.len and data[i + 1] == '[') {
            // Skip DA responses which have '?' after CSI
            if (i + 2 < data.len and data[i + 2] == '?') {
                i += 3;
                continue;
            }
            if (matchSeq(data[i..], DA2_QUERY) or matchSeq(data[i..], DA2_QUERY_EXPLICIT)) {
                _ = posix.write(pty_fd, DA2_RESPONSE) catch {};
            } else if (matchSeq(data[i..], DA1_QUERY) or matchSeq(data[i..], DA1_QUERY_EXPLICIT)) {
                _ = posix.write(pty_fd, DA1_RESPONSE) catch {};
            }
        }
        i += 1;
    }
}

fn matchSeq(data: []const u8, seq: []const u8) bool {
    if (data.len < seq.len) return false;
    return std.mem.eql(u8, data[0..seq.len], seq);
}

pub fn findTaskExitMarker(output: []const u8) ?u8 {
    const marker = "ZMX_TASK_COMPLETED:";

    // Search for marker in output
    if (std.mem.indexOf(u8, output, marker)) |idx| {
        const after_marker = output[idx + marker.len ..];

        // Find the exit code number and newline
        var end_idx: usize = 0;
        while (end_idx < after_marker.len and after_marker[end_idx] != '\n' and after_marker[end_idx] != '\r') {
            end_idx += 1;
        }

        const exit_code_str = after_marker[0..end_idx];

        // Parse exit code
        if (std.fmt.parseInt(u8, exit_code_str, 10)) |exit_code| {
            return exit_code;
        } else |_| {
            std.log.warn("failed to parse task exit code from: {s}", .{exit_code_str});
            return null;
        }
    }

    return null;
}

/// Detects Kitty keyboard protocol escape sequence for Ctrl+\
/// 92 = backslash, 5 = ctrl modifier, :1 = key press event
pub fn isKittyCtrlBackslash(buf: []const u8) bool {
    return std.mem.indexOf(u8, buf, "\x1b[92;5u") != null or
        std.mem.indexOf(u8, buf, "\x1b[92;5:1u") != null;
}

pub fn serializeTerminalState(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal) ?[]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var term_formatter = ghostty_vt.formatter.TerminalFormatter.init(term, .vt);
    term_formatter.content = .{ .selection = null };
    term_formatter.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false, // tabstop restoration moves cursor after CUP, corrupting position
        .pwd = true,
        .keyboard = true,
        .screen = .all,
    };

    term_formatter.format(&builder.writer) catch |err| {
        std.log.warn("failed to format terminal state err={s}", .{@errorName(err)});
        return null;
    };

    const output = builder.writer.buffered();
    if (output.len == 0) return null;

    return alloc.dupe(u8, output) catch |err| {
        std.log.warn("failed to allocate terminal state err={s}", .{@errorName(err)});
        return null;
    };
}

pub const HistoryFormat = enum(u8) {
    plain = 0,
    vt = 1,
    html = 2,
};

pub fn serializeTerminal(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal, format: HistoryFormat) ?[]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    const opts: ghostty_vt.formatter.Options = switch (format) {
        .plain => .plain,
        .vt => .vt,
        .html => .html,
    };
    var term_formatter = ghostty_vt.formatter.TerminalFormatter.init(term, opts);
    term_formatter.content = .{ .selection = null };
    term_formatter.extra = switch (format) {
        .plain => .none,
        .vt => .{
            .palette = false,
            .modes = true,
            .scrolling_region = true,
            .tabstops = false,
            .pwd = true,
            .keyboard = true,
            .screen = .all,
        },
        .html => .styles,
    };

    term_formatter.format(&builder.writer) catch |err| {
        std.log.warn("failed to format terminal err={s}", .{@errorName(err)});
        return null;
    };

    const output = builder.writer.buffered();
    if (output.len == 0) return null;

    return alloc.dupe(u8, output) catch |err| {
        std.log.warn("failed to allocate terminal output err={s}", .{@errorName(err)});
        return null;
    };
}

pub fn detectShell() [:0]const u8 {
    return std.posix.getenv("SHELL") orelse "/bin/sh";
}

/// Formats a session entry for list output (only the name when `short` is
/// true), adding a prefix to indicate the current session, if there is one.
pub fn writeSessionLine(writer: *std.Io.Writer, session: SessionEntry, short: bool, current_session: ?[]const u8) !void {
    const current_arrow = "→";
    const prefix = if (current_session) |current|
        if (std.mem.eql(u8, current, session.name)) current_arrow ++ " " else "  "
    else
        "";

    if (short) {
        if (session.is_error) return;
        try writer.print("{s}\n", .{session.name});
        return;
    }

    if (session.is_error) {
        try writer.print("{s}name={s}\terr={s}\tstatus=cleaning up\n", .{
            prefix,
            session.name,
            session.error_name.?,
        });
        return;
    }

    try writer.print("{s}name={s}\tpid={d}\tclients={d}\tcreated={d}", .{
        prefix,
        session.name,
        session.pid.?,
        session.clients_len.?,
        session.created_at,
    });
    if (session.cwd) |cwd| {
        try writer.print("\tstart_dir={s}", .{cwd});
    }
    if (session.cmd) |cmd| {
        try writer.print("\tcmd={s}", .{cmd});
    }
    if (session.task_ended_at) |ended_at| {
        if (ended_at > 0) {
            try writer.print("\tended={d}", .{ended_at});

            if (session.task_exit_code) |exit_code| {
                try writer.print("\texit_code={d}", .{exit_code});
            }
        }
    }
    try writer.print("\n", .{});
}

test "writeSessionLine formats output for current session and short output" {
    const Case = struct {
        session: SessionEntry,
        short: bool,
        current_session: ?[]const u8,
        expected: []const u8,
    };

    const session = SessionEntry{
        .name = "dev",
        .pid = 123,
        .clients_len = 2,
        .is_error = false,
        .error_name = null,
        .cmd = null,
        .cwd = null,
        .created_at = 0,
        .task_ended_at = null,
        .task_exit_code = null,
    };

    const cases = [_]Case{
        .{
            .session = session,
            .short = false,
            .current_session = "dev",
            .expected = "→ name=dev\tpid=123\tclients=2\tcreated=0\n",
        },
        .{
            .session = session,
            .short = false,
            .current_session = "other",
            .expected = "  name=dev\tpid=123\tclients=2\tcreated=0\n",
        },
        .{
            .session = session,
            .short = false,
            .current_session = null,
            .expected = "name=dev\tpid=123\tclients=2\tcreated=0\n",
        },
        .{
            .session = session,
            .short = true,
            .current_session = "dev",
            .expected = "dev\n",
        },
        .{
            .session = session,
            .short = true,
            .current_session = "other",
            .expected = "dev\n",
        },
        .{
            .session = session,
            .short = true,
            .current_session = null,
            .expected = "dev\n",
        },
    };

    for (cases) |case| {
        var builder: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer builder.deinit();

        try writeSessionLine(&builder.writer, case.session, case.short, case.current_session);
        try std.testing.expectEqualStrings(case.expected, builder.writer.buffered());
    }
}

test "shellNeedsQuoting" {
    try std.testing.expect(shellNeedsQuoting(""));
    try std.testing.expect(shellNeedsQuoting("hello world"));
    try std.testing.expect(shellNeedsQuoting("hello!"));
    try std.testing.expect(shellNeedsQuoting("$PATH"));
    try std.testing.expect(shellNeedsQuoting("it's"));
    try std.testing.expect(shellNeedsQuoting("a|b"));
    try std.testing.expect(shellNeedsQuoting("a;b"));
    try std.testing.expect(!shellNeedsQuoting("hello"));
    try std.testing.expect(!shellNeedsQuoting("bash"));
    try std.testing.expect(!shellNeedsQuoting("-c"));
    try std.testing.expect(!shellNeedsQuoting("/usr/bin/env"));
}

test "shellQuote" {
    const alloc = std.testing.allocator;

    const empty = try shellQuote(alloc, "");
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("''", empty);

    const space = try shellQuote(alloc, "hello world");
    defer alloc.free(space);
    try std.testing.expectEqualStrings("'hello world'", space);

    const bang = try shellQuote(alloc, "hello!");
    defer alloc.free(bang);
    try std.testing.expectEqualStrings("'hello!'", bang);

    const dollar = try shellQuote(alloc, "$PATH");
    defer alloc.free(dollar);
    try std.testing.expectEqualStrings("'$PATH'", dollar);

    const sq = try shellQuote(alloc, "it's");
    defer alloc.free(sq);
    try std.testing.expectEqualStrings("'it'\\''s'", sq);

    const dq = try shellQuote(alloc, "say \"hi\"");
    defer alloc.free(dq);
    try std.testing.expectEqualStrings("'say \"hi\"'", dq);

    const both = try shellQuote(alloc, "it's \"cool\"");
    defer alloc.free(both);
    try std.testing.expectEqualStrings("'it'\\''s \"cool\"'", both);

    // just a single quote
    const lone_sq = try shellQuote(alloc, "'");
    defer alloc.free(lone_sq);
    try std.testing.expectEqualStrings("''\\'''", lone_sq);

    // multiple consecutive single quotes
    const triple_sq = try shellQuote(alloc, "'''");
    defer alloc.free(triple_sq);
    try std.testing.expectEqualStrings("''\\'''\\'''\\'''", triple_sq);

    // backtick command substitution
    const backtick = try shellQuote(alloc, "`whoami`");
    defer alloc.free(backtick);
    try std.testing.expectEqualStrings("'`whoami`'", backtick);

    // dollar command substitution
    const dollar_cmd = try shellQuote(alloc, "$(whoami)");
    defer alloc.free(dollar_cmd);
    try std.testing.expectEqualStrings("'$(whoami)'", dollar_cmd);

    // glob
    const glob = try shellQuote(alloc, "*.txt");
    defer alloc.free(glob);
    try std.testing.expectEqualStrings("'*.txt'", glob);

    // tilde
    const tilde = try shellQuote(alloc, "~/file");
    defer alloc.free(tilde);
    try std.testing.expectEqualStrings("'~/file'", tilde);

    // trailing backslash
    const trailing_bs = try shellQuote(alloc, "path\\");
    defer alloc.free(trailing_bs);
    try std.testing.expectEqualStrings("'path\\'", trailing_bs);

    // semicolon (command injection)
    const semi = try shellQuote(alloc, "; rm -rf /");
    defer alloc.free(semi);
    try std.testing.expectEqualStrings("'; rm -rf /'", semi);

    // embedded newline
    const newline = try shellQuote(alloc, "line1\nline2");
    defer alloc.free(newline);
    try std.testing.expectEqualStrings("'line1\nline2'", newline);

    // parentheses (subshell)
    const parens = try shellQuote(alloc, "(echo hi)");
    defer alloc.free(parens);
    try std.testing.expectEqualStrings("'(echo hi)'", parens);

    // heredoc marker
    const heredoc = try shellQuote(alloc, "<<EOF");
    defer alloc.free(heredoc);
    try std.testing.expectEqualStrings("'<<EOF'", heredoc);

    // no quoting needed -- plain word should still be quoted
    // (shellQuote is only called when shellNeedsQuoting returns true,
    // but verify it produces valid output anyway)
    const plain = try shellQuote(alloc, "hello");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("'hello'", plain);
}

test "isKittyCtrlBackslash" {
    try std.testing.expect(isKittyCtrlBackslash("\x1b[92;5u"));
    try std.testing.expect(isKittyCtrlBackslash("\x1b[92;5:1u"));
    try std.testing.expect(!isKittyCtrlBackslash("\x1b[92;5:3u"));
    try std.testing.expect(!isKittyCtrlBackslash("\x1b[92;1u"));
    try std.testing.expect(!isKittyCtrlBackslash("garbage"));
}
