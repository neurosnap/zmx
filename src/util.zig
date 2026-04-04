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

pub fn get_session_entries(
    alloc: std.mem.Allocator,
    socket_dir: []const u8,
) !std.ArrayList(SessionEntry) {
    var dir = try std.fs.openDirAbsolute(socket_dir, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();

    var sessions = try std.ArrayList(SessionEntry).initCapacity(alloc, 30);

    while (try iter.next()) |entry| {
        const exists = socket.sessionExists(dir, entry.name) catch continue;
        if (exists) {
            const name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(name);

            const socket_path = socket.getSocketPath(alloc, socket_dir, entry.name) catch |err| switch (err) {
                error.NameTooLong => continue,
                error.OutOfMemory => return err,
            };
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
                // Only clean up when the daemon is definitively gone. A busy
                // daemon can miss the probe timeout; deleting its socket
                // orphans it permanently.
                if (err == error.ConnectionRefused) {
                    socket.cleanupStaleSocket(dir, entry.name);
                }
                continue;
            };
            posix.close(result.fd);

            // Extract cmd and cwd from the fixed-size arrays. Lengths come
            // off the wire (u16 range), so clamp to the actual array size.
            const cmd_len = @min(result.info.cmd_len, ipc.MAX_CMD_LEN);
            const cwd_len = @min(result.info.cwd_len, ipc.MAX_CWD_LEN);
            const cmd: ?[]const u8 = if (cmd_len > 0)
                alloc.dupe(u8, result.info.cmd[0..cmd_len]) catch null
            else
                null;
            const cwd: ?[]const u8 = if (cwd_len > 0)
                alloc.dupe(u8, result.info.cwd[0..cwd_len]) catch null
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
            ' ', '\t', '"', '\'', '\\', '$', '`', '!', '(', ')', '{', '}', '[', ']' => return true,
            '|', '&', ';', '<', '>', '?', '*', '~', '#', '\n' => return true,
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

pub fn respondToDeviceAttributes(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), data: []const u8) void {
    // Scan for DA queries in PTY output and respond on behalf of the terminal.
    // This handles the case where no client is attached (e.g. zmx run)
    // and the shell (e.g. fish) sends a DA query that would otherwise go unanswered.
    //
    // Responses are queued into the daemon's pty_write_buf (not written
    // directly) so they don't interleave with any already-buffered input —
    // e.g. a large `zmx run` payload still draining after the client
    // disconnected.
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
                buf.appendSlice(alloc, DA2_RESPONSE) catch {};
            } else if (matchSeq(data[i..], DA1_QUERY) or matchSeq(data[i..], DA1_QUERY_EXPLICIT)) {
                buf.appendSlice(alloc, DA1_RESPONSE) catch {};
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

/// Detects Kitty keyboard protocol escape sequence for Ctrl+\.
/// Parses the general CSI u form:
///   CSI key-code[:alternates] ; modifiers[:event-type] [; text-codepoints] u
///
/// Matches when key-code is 92 (backslash), ctrl bit is set in modifiers,
/// and event type is press (1 or absent) or repeat (2). Rejects release (3).
/// Tolerates additional modifiers (caps_lock, num_lock)
/// and alternate key sub-fields from the kitty protocol's progressive
/// enhancement flags.
pub fn isKittyCtrlBackslash(buf: []const u8) bool {
    return detectCsiKeyPress(buf, 92, 0b100);
}

fn detectCsiKeyPress(buf: []const u8, expected_key: u32, expected_mods: u32) bool {
    // Scan for any CSI u sequence encoding the given Ctrl+key in the buffer.
    // The sequence can appear at any offset (e.g. preceded by other input).
    var i: usize = 0;
    while (i + 2 < buf.len) : (i += 1) {
        if (buf[i] == 0x1b and buf[i + 1] == '[') {
            if (isKeyPressed(buf[i + 2 ..], expected_key, expected_mods)) return true;
        }
    }
    return false;
}

fn isKeyPressed(buf: []const u8, expected_key: u32, expected_mods: u32) bool {
    var pos: usize = 0;

    // 1. Parse key code.
    const key_code = parseDecimal(buf, &pos) orelse return false;
    if (key_code != expected_key) return false;

    // 2. Skip any ':alternate-key' sub-fields (shifted key, base layout key).
    while (pos < buf.len and buf[pos] == ':') {
        pos += 1; // consume ':'
        _ = parseDecimal(buf, &pos); // consume digits (may be empty for ::base)
    }

    // 3. Expect ';' separator before modifiers.
    if (pos >= buf.len or buf[pos] != ';') return false;
    pos += 1;

    // 4. Parse modifier value. Kitty encodes as 1 + bitfield.
    const mod_encoded = parseDecimal(buf, &pos) orelse return false;
    if (mod_encoded < 1) return false;
    const mod_raw = mod_encoded - 1;

    // 5. Only accept intentional modifiers. Lock modifiers
    //    (caps_lock=0b1000000, num_lock=0b10000000) are tolerated because
    //    they are ambient state, not deliberate key combinations.
    const intentional_mods = mod_raw & 0b00111111;
    if (intentional_mods != expected_mods) return false;

    // 6. Parse optional event type after ':'.
    if (pos < buf.len and buf[pos] == ':') {
        pos += 1;
        const event_type = parseDecimal(buf, &pos) orelse return false;
        // 3 = release -- reject. Accept press (1) and repeat (2).
        if (event_type == 3) return false;
    }

    // 7. Skip optional ';text-codepoints' section.
    if (pos < buf.len and buf[pos] == ';') {
        pos += 1;
        // Consume remaining digits and colons until 'u'.
        while (pos < buf.len and (std.ascii.isDigit(buf[pos]) or buf[pos] == ':')) {
            pos += 1;
        }
    }

    // 8. Expect terminal 'u'.
    return pos < buf.len and buf[pos] == 'u';
}

/// Parse a decimal integer from buf starting at pos, advancing pos past the
/// consumed digits. Returns null if no digits are present.
fn parseDecimal(buf: []const u8, pos: *usize) ?u32 {
    const start = pos.*;
    var value: u32 = 0;
    while (pos.* < buf.len and std.ascii.isDigit(buf[pos.*])) {
        value = value *% 10 +% (buf[pos.*] - '0');
        pos.* += 1;
    }
    if (pos.* == start) return null;
    return value;
}

pub fn serializeTerminalState(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal) ?[]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    // Synchronized output (DECSET 2026) is a transient rendering handshake
    // between a program and its current terminal client. Replaying it to a
    // newly attached client can leave that client deferring renders until its
    // local timeout fires, so temporarily exclude it from restored state and
    // restore the original mode before returning.
    const had_synchronized_output = term.modes.get(.synchronized_output);
    if (had_synchronized_output) {
        term.modes.set(.synchronized_output, false);
        defer term.modes.set(.synchronized_output, true);
    }

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

pub fn serializeTerminal(
    alloc: std.mem.Allocator,
    term: *ghostty_vt.Terminal,
    format: HistoryFormat,
) ?[]const u8 {
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
pub fn writeSessionLine(
    writer: *std.Io.Writer,
    session: SessionEntry,
    short: bool,
    current_session: ?[]const u8,
) !void {
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
        // "cleaning up" is only truthful when the probe was definitively
        // refused (socket deleted this pass). On Timeout/Unexpected the
        // daemon may just be busy, so don't lie about what we did.
        const status = if (std.mem.eql(u8, session.error_name.?, "ConnectionRefused"))
            "cleaning up"
        else
            "unreachable";
        try writer.print("{s}name={s}\terr={s}\tstatus={s}\n", .{
            prefix,
            session.name,
            session.error_name.?,
            status,
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
    const expect = std.testing.expect;

    // Basic: ctrl only (modifier 5 = 1 + 4)
    try expect(isKittyCtrlBackslash("\x1b[92;5u"));

    // Explicit press event type (:1)
    try expect(isKittyCtrlBackslash("\x1b[92;5:1u"));

    // Repeat event (:2) -- user holding Ctrl+\
    try expect(isKittyCtrlBackslash("\x1b[92;5:2u"));

    // Release event (:3) -- must NOT trigger detach
    try expect(!isKittyCtrlBackslash("\x1b[92;5:3u"));

    // Lock modifiers: caps_lock (bit 6) changes modifier value
    // ctrl + caps_lock = 1 + (4 + 64) = 69
    try expect(isKittyCtrlBackslash("\x1b[92;69u"));
    try expect(isKittyCtrlBackslash("\x1b[92;69:1u"));
    try expect(!isKittyCtrlBackslash("\x1b[92;69:3u"));

    // ctrl + num_lock = 1 + (4 + 128) = 133
    try expect(isKittyCtrlBackslash("\x1b[92;133u"));

    // ctrl + caps_lock + num_lock = 1 + (4 + 64 + 128) = 197
    try expect(isKittyCtrlBackslash("\x1b[92;197u"));

    // Combined intentional modifiers -- must NOT match (ctrl+\ is the
    // detach key, not ctrl+shift+\ or ctrl+alt+\)
    // ctrl + shift = 1 + (4 + 1) = 6
    try expect(!isKittyCtrlBackslash("\x1b[92;6u"));

    // ctrl + alt = 1 + (4 + 2) = 7
    try expect(!isKittyCtrlBackslash("\x1b[92;7u"));

    // ctrl + super = 1 + (4 + 8) = 13
    try expect(!isKittyCtrlBackslash("\x1b[92;13u"));

    // ctrl + shift + caps_lock = 1 + (1 + 4 + 64) = 70 -- shift is intentional
    try expect(!isKittyCtrlBackslash("\x1b[92;70u"));

    // ctrl + shift + num_lock = 1 + (1 + 4 + 128) = 134 -- shift is intentional
    try expect(!isKittyCtrlBackslash("\x1b[92;134u"));

    // Modifier without ctrl bit -- must NOT match
    // shift only = 1 + 1 = 2
    try expect(!isKittyCtrlBackslash("\x1b[92;1u"));
    try expect(!isKittyCtrlBackslash("\x1b[92;2u"));

    // Alternate key sub-fields (report_alternates flag)
    // shifted key | (124): \x1b[92:124;5u
    try expect(isKittyCtrlBackslash("\x1b[92:124;5u"));

    // base layout key only (non-US keyboard): \x1b[92::92;5u
    try expect(isKittyCtrlBackslash("\x1b[92::92;5u"));

    // both shifted and base layout: \x1b[92:124:92;5u
    try expect(isKittyCtrlBackslash("\x1b[92:124:92;5u"));

    // Alternate keys + lock modifiers + event type
    try expect(isKittyCtrlBackslash("\x1b[92:124;69:1u"));
    try expect(!isKittyCtrlBackslash("\x1b[92:124;69:3u"));

    // Text codepoints section (flag 0b10000) -- tolerated and skipped
    // Even though ctrl+\ text is typically empty, terminals may vary
    try expect(isKittyCtrlBackslash("\x1b[92;5;28u"));
    try expect(isKittyCtrlBackslash("\x1b[92;5;28:92u"));

    // Wrong key code -- must NOT match
    try expect(!isKittyCtrlBackslash("\x1b[91;5u"));
    try expect(!isKittyCtrlBackslash("\x1b[93;5u"));
    try expect(!isKittyCtrlBackslash("\x1b[9;5u"));
    try expect(!isKittyCtrlBackslash("\x1b[920;5u"));

    // Sequence embedded in larger buffer (e.g., preceded by other input)
    try expect(isKittyCtrlBackslash("abc\x1b[92;5u"));
    try expect(isKittyCtrlBackslash("\x1b[A\x1b[92;5u"));

    // Garbage / malformed inputs
    try expect(!isKittyCtrlBackslash("garbage"));
    try expect(!isKittyCtrlBackslash(""));
    try expect(!isKittyCtrlBackslash("\x1b["));
    try expect(!isKittyCtrlBackslash("\x1b[92"));
    try expect(!isKittyCtrlBackslash("\x1b[92;"));
    try expect(!isKittyCtrlBackslash("\x1b[92;u"));
    try expect(!isKittyCtrlBackslash("\x1b[;5u"));

    // Other CSI u sequences that happen to contain '92' elsewhere
    try expect(!isKittyCtrlBackslash("\x1b[65;92u"));
}

test "serializeTerminalState excludes synchronized output replay" {
    const alloc = std.testing.allocator;

    var term = try ghostty_vt.Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    try stream.nextSlice("\x1b[?2004h"); // Bracketed paste
    try stream.nextSlice("\x1b[?2026h"); // Synchronized output
    try stream.nextSlice("hello");

    try std.testing.expect(term.modes.get(.bracketed_paste));
    try std.testing.expect(term.modes.get(.synchronized_output));

    const output = serializeTerminalState(alloc, &term) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try std.testing.expect(term.modes.get(.synchronized_output));

    var restored = try ghostty_vt.Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer restored.deinit(alloc);

    var restored_stream = restored.vtStream();
    defer restored_stream.deinit();
    try restored_stream.nextSlice(output);

    try std.testing.expect(restored.modes.get(.bracketed_paste));
    try std.testing.expect(!restored.modes.get(.synchronized_output));
}
