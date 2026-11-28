const std = @import("std");
const build_options = @import("build_options");
const has_daemon = if (@hasDecl(build_options, "has_daemon")) build_options.has_daemon else true;
pub const terminal = if (has_daemon) @import("terminal.zig") else struct {};
pub const isUserInput = if (has_daemon) terminal.isUserInput else struct {};
pub const serializeTerminalState = if (has_daemon) terminal.serializeTerminalState else struct {};
pub const serializeTerminal = if (has_daemon) terminal.serializeTerminal else struct {};
pub const serializeTerminalRange = if (has_daemon) terminal.serializeTerminalRange else struct {};
const ipc = @import("ipc.zig");
const socket = @import("socket.zig");
const cross = @import("cross");
const label = @import("label.zig");
const lib_posix = @import("posix.zig");
const testing = std.testing;

pub const SessionEntry = struct {
    name: []const u8,
    pid: ?i32,
    clients_len: ?usize,
    is_error: bool,
    error_name: ?[]const u8,
    cmd: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    created_at: u64,
    task_ended_at: ?u64,
    task_exit_code: ?u8,

    pub fn deinit(self: SessionEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        if (self.cmd) |cmd| alloc.free(cmd);
        if (self.cwd) |cwd| alloc.free(cwd);
        if (self.labels) |l| alloc.free(l);
    }

    pub fn lessThan(_: void, a: SessionEntry, b: SessionEntry) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

pub fn get_session_entries(
    alloc: std.mem.Allocator,
    io: std.Io,
    socket_dir: []const u8,
) !std.ArrayList(SessionEntry) {
    var dir = try std.Io.Dir.openDirAbsolute(io, socket_dir, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();

    var sessions = try std.ArrayList(SessionEntry).initCapacity(alloc, 30);

    while (try iter.next(io)) |entry| {
        const exists = socket.sessionExists(io, dir, entry.name) catch continue;
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
                    .labels = "",
                });
                // Only clean up when the daemon is definitively gone. A busy
                // daemon can miss the probe timeout; deleting its socket
                // orphans it permanently.
                if (err == error.ConnectionRefused) {
                    socket.cleanupStaleSocket(io, dir, entry.name);
                }
                continue;
            };
            defer result.deinit();

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

            const labels = if (result.labels) |lbl|
                alloc.dupe(u8, lbl) catch null
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
                .labels = labels,
                .created_at = result.info.created_at,
                .task_ended_at = result.info.task_ended_at,
                .task_exit_code = result.info.task_exit_code,
            });
        }
    }

    return sessions;
}

/// getCwd get the current working directory in a std.Uri format.
/// Caller is responsible for releasing memory.
pub fn getCwd(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const cur_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cur_path);

    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = try std.posix.gethostname(&buf);

    return std.fmt.allocPrint(gpa, "file://{s}{s}", .{ hostname, cur_path });
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

pub fn generateTaskId(io: std.Io) [4]u8 {
    var bytes: [2]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn getTaskExitMarker(buf: []u8, id_marker: [4]u8) ![]u8 {
    return std.fmt.bufPrint(buf, "ZMX_TASK_COMPLETED:{s}:", .{id_marker});
}

pub fn findTaskExitMarker(output: []const u8, id_marker: [4]u8) !?u8 {
    var buf: [1024]u8 = undefined;
    const marker = try getTaskExitMarker(&buf, id_marker);

    // The command line is echoed back by the PTY (canonical mode) before the
    // shell evaluates it, so the *first* occurrence of the marker in the
    // output is often the literal, unexpanded "ZMX_TASK_COMPLETED:{id}:$?" from
    // the echo, not the real "ZMX_TASK_COMPLETED:{id}:<code>" written once the
    // shell actually runs it. Keep scanning past unparseable occurrences
    // instead of giving up on the first one.
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, output, search_start, marker)) |idx| {
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
            search_start = idx + marker.len;
        }
    }

    return null;
}

/// Strip ANSI escape sequences from data, returning only printable characters
/// and essential whitespace (CR, LF, tab, backspace).
/// The returned slice is owned by the caller and must be freed.
pub fn stripAnsi(alloc: std.mem.Allocator, data: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).initCapacity(alloc, data.len) catch unreachable;
    defer result.deinit(alloc);

    var i: usize = 0;
    while (i < data.len) {
        const c = data[i];
        if (c == 0x1b) {
            i += 1;
            if (i >= data.len) break;
            const next = data[i];
            if (next == '[') { // CSI
                i += 1;
                while (i < data.len) : (i += 1) {
                    const b = data[i];
                    if (b >= 0x40 and b <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
            } else if (next == ']') { // OSC
                i += 1;
                while (i < data.len) : (i += 1) {
                    const b = data[i];
                    if (b == 0x07) {
                        i += 1;
                        break;
                    }
                    if (b == 0x1b and i + 1 < data.len and data[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            } else if (next == 'P' or next == 'X' or next == '^' or next == '_') { // DCS, SOS, PM, APC
                i += 1;
                while (i < data.len) : (i += 1) {
                    if (data[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            } else {
                // 2-byte escape sequence (e.g. ESC c)
                i += 1;
            }
        } else {
            switch (c) {
                '\r', '\n', '\t', 0x08 => try result.append(alloc, c),
                0x7f => {},
                else => if (c >= 0x20) try result.append(alloc, c),
            }
            i += 1;
        }
    }
    return result.toOwnedSlice(alloc);
}

/// Dcts Ctrl+\ across raw, Kitty CSI u, and xterm modifyOtherKeys encodings.
pub fn isCtrlBackslash(buf: []const u8) bool {
    if (buf.len == 0) return false;
    return buf[0] == 0x1C or isKeyPressed(buf, 0x5c, 0b100) or isModifyOtherKey(buf, 0x5c, 0b100);
}

/// Scans the buffer for an xterm modifyOtherKeys-encoded keypress.
/// Format: CSI 27 ; <modifier> ; <keycode> ~
/// Reference: invisible-island.net/xterm/ctlseqs/ctlseqs.html (modifyOtherKeys).
fn isModifyOtherKey(buf: []const u8, expected_key: u32, expected_mods: u32) bool {
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 1) {
        if (buf[i] == 0x1b and buf[i + 1] == '[') {
            if (modifyOtherMatches(buf[i + 2 ..], expected_key, expected_mods)) return true;
        }
    }
    return false;
}

/// Parses the body of an xterm modifyOtherKeys CSI sequence (after the leading
/// `\x1b[`). Mirrors keypressWithMod's tolerance for lock modifiers.
fn modifyOtherMatches(buf: []const u8, expected_key: u32, expected_mods: u32) bool {
    var pos: usize = 0;

    // 1. Sentinel: literal "27" identifies xterm modifyOtherKeys.
    const sentinel = parseDecimal(buf, &pos) orelse return false;
    if (sentinel != 27) return false;

    // 2. Expect ';' before modifier.
    if (pos >= buf.len or buf[pos] != ';') return false;
    pos += 1;

    // 3. Parse modifier (xterm encodes as 1 + bitfield, same as kitty).
    const mod_encoded = parseDecimal(buf, &pos) orelse return false;
    if (mod_encoded < 1) return false;
    const mod_raw = mod_encoded - 1;
    // Tolerate ambient lock modifiers (caps_lock=64, num_lock=128).
    const intentional_mods = mod_raw & 0b00111111;
    if (expected_mods > 0 and expected_mods != intentional_mods) return false;

    // 4. Expect ';' before keycode.
    if (pos >= buf.len or buf[pos] != ';') return false;
    pos += 1;

    // 5. Parse keycode.
    const key_code = parseDecimal(buf, &pos) orelse return false;
    if (key_code != expected_key) return false;

    // 6. Expect '~' terminator.
    return pos < buf.len and buf[pos] == '~';
}

/// Returns true when the user has opted out of the ctrl+\ detach shortcut
/// via ZMX_NO_DETACH_KEY, e.g. to free up ctrl+\ for an inner program
/// like vim, which uses ctrl+\ ctrl+n to escape its own terminal mode.
pub fn isDetachKeyDisabled() bool {
    return lib_posix.getenv("ZMX_NO_DETACH_KEY") != null;
}

/// Detects vt100 or kitty keyboard protocol escape sequence for up arrow.
pub fn isUpArrow(buf: []const u8) bool {
    return std.mem.eql(u8, buf, "\x1b[A") or std.mem.eql(u8, buf, "\x1b[1;1:1A");
}

fn isKeyPressed(buf: []const u8, expected_key: u32, expected_mods: u32) bool {
    // Scan for any CSI u sequence encoding in the buffer.
    var i: usize = 0;
    while (i + 2 < buf.len) : (i += 1) {
        if (buf[i] == 0x1b and buf[i + 1] == '[') {
            if (keypressWithMod(buf[i + 2 ..], expected_key, expected_mods)) return true;
        }
    }
    return false;
}

/// Parses the general CSI u form:
///   CSI key-code[:alternates] ; modifiers[:event-type] [; text-codepoints] u
///
/// Event type is press (1 or absent) or repeat (2). Rejects release (3).
/// Tolerates additional modifiers (caps_lock, num_lock)
/// and alternate key sub-fields from the kitty protocol's progressive
/// enhancement flags.
fn keypressWithMod(buf: []const u8, expected_key: u32, expected_mods: u32) bool {
    const parsed = parseKittyCsiU(buf) orelse return false;
    if (parsed.key_code != expected_key) return false;

    // Only accept intentional modifiers. Lock modifiers
    // (caps_lock=0b1000000, num_lock=0b10000000) are tolerated because
    // they are ambient state, not deliberate key combinations.
    const intentional_mods = parsed.modifiers & 0b00111111;
    if (expected_mods > 0 and expected_mods != intentional_mods) return false;

    // 3 = release -- reject. Accept press (1) and repeat (2).
    return parsed.event_type != 3;
}

pub const KittyCsiU = struct {
    key_code: u32,
    modifiers: u32,
    event_type: u32,
    consumed: usize,
};

pub fn parseKittyCsiU(buf: []const u8) ?KittyCsiU {
    var pos: usize = 0;

    // 1. Parse key code.
    const key_code = parseDecimal(buf, &pos) orelse return null;

    // 2. Skip any ':alternate-key' sub-fields (shifted key, base layout key).
    while (pos < buf.len and buf[pos] == ':') {
        pos += 1; // consume ':'
        _ = parseDecimal(buf, &pos); // consume digits (may be empty for ::base)
    }

    // 3. Expect ';' separator before modifiers.
    if (pos >= buf.len or buf[pos] != ';') return null;
    pos += 1;

    // 4. Parse modifier value. Kitty encodes as 1 + bitfield.
    const mod_encoded = parseDecimal(buf, &pos) orelse return null;
    if (mod_encoded < 1) return null;
    const mod_raw = mod_encoded - 1;

    var event_type: u32 = 1;
    // 5. Parse optional event type after ':'.
    if (pos < buf.len and buf[pos] == ':') {
        pos += 1;
        event_type = parseDecimal(buf, &pos) orelse return null;
    }

    // 6. Skip optional ';text-codepoints' section.
    if (pos < buf.len and buf[pos] == ';') {
        pos += 1;
        // Consume remaining digits and colons until 'u'.
        while (pos < buf.len and (std.ascii.isDigit(buf[pos]) or buf[pos] == ':')) {
            pos += 1;
        }
    }

    // 7. Expect terminal 'u'.
    if (pos >= buf.len or buf[pos] != 'u') return null;
    pos += 1;

    return .{
        .key_code = key_code,
        .modifiers = mod_raw,
        .event_type = event_type,
        .consumed = pos,
    };
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

pub const HistoryFormat = enum(u8) {
    plain = 0,
    vt = 1,
    html = 2,
};

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
        try writer.print("\tcwd={s}", .{cwd});
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
    if (session.labels) |labels| {
        var kvs = label.LabelIterator.init(labels);
        while (kvs.next()) |kv| {
            try writer.print("\t{s}={s}", .{ kv.key, kv.value });
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
        var builder: std.Io.Writer.Allocating = .init(testing.allocator);
        defer builder.deinit();

        try writeSessionLine(&builder.writer, case.session, case.short, case.current_session);
        try testing.expectEqualStrings(case.expected, builder.writer.buffered());
    }
}

test "shellNeedsQuoting" {
    try testing.expect(shellNeedsQuoting(""));
    try testing.expect(shellNeedsQuoting("hello world"));
    try testing.expect(shellNeedsQuoting("hello!"));
    try testing.expect(shellNeedsQuoting("$PATH"));
    try testing.expect(shellNeedsQuoting("it's"));
    try testing.expect(shellNeedsQuoting("a|b"));
    try testing.expect(shellNeedsQuoting("a;b"));
    try testing.expect(!shellNeedsQuoting("hello"));
    try testing.expect(!shellNeedsQuoting("bash"));
    try testing.expect(!shellNeedsQuoting("-c"));
    try testing.expect(!shellNeedsQuoting("/usr/bin/env"));
}

test "shellQuote" {
    const alloc = testing.allocator;

    const empty = try shellQuote(alloc, "");
    defer alloc.free(empty);
    try testing.expectEqualStrings("''", empty);

    const space = try shellQuote(alloc, "hello world");
    defer alloc.free(space);
    try testing.expectEqualStrings("'hello world'", space);

    const bang = try shellQuote(alloc, "hello!");
    defer alloc.free(bang);
    try testing.expectEqualStrings("'hello!'", bang);

    const dollar = try shellQuote(alloc, "$PATH");
    defer alloc.free(dollar);
    try testing.expectEqualStrings("'$PATH'", dollar);

    const sq = try shellQuote(alloc, "it's");
    defer alloc.free(sq);
    try testing.expectEqualStrings("'it'\\''s'", sq);

    const dq = try shellQuote(alloc, "say \"hi\"");
    defer alloc.free(dq);
    try testing.expectEqualStrings("'say \"hi\"'", dq);

    const both = try shellQuote(alloc, "it's \"cool\"");
    defer alloc.free(both);
    try testing.expectEqualStrings("'it'\\''s \"cool\"'", both);

    // just a single quote
    const lone_sq = try shellQuote(alloc, "'");
    defer alloc.free(lone_sq);
    try testing.expectEqualStrings("''\\'''", lone_sq);

    // multiple consecutive single quotes
    const triple_sq = try shellQuote(alloc, "'''");
    defer alloc.free(triple_sq);
    try testing.expectEqualStrings("''\\'''\\'''\\'''", triple_sq);

    // backtick command substitution
    const backtick = try shellQuote(alloc, "`whoami`");
    defer alloc.free(backtick);
    try testing.expectEqualStrings("'`whoami`'", backtick);

    // dollar command substitution
    const dollar_cmd = try shellQuote(alloc, "$(whoami)");
    defer alloc.free(dollar_cmd);
    try testing.expectEqualStrings("'$(whoami)'", dollar_cmd);

    // glob
    const glob = try shellQuote(alloc, "*.txt");
    defer alloc.free(glob);
    try testing.expectEqualStrings("'*.txt'", glob);

    // tilde
    const tilde = try shellQuote(alloc, "~/file");
    defer alloc.free(tilde);
    try testing.expectEqualStrings("'~/file'", tilde);

    // trailing backslash
    const trailing_bs = try shellQuote(alloc, "path\\");
    defer alloc.free(trailing_bs);
    try testing.expectEqualStrings("'path\\'", trailing_bs);

    // semicolon (command injection)
    const semi = try shellQuote(alloc, "; rm -rf /");
    defer alloc.free(semi);
    try testing.expectEqualStrings("'; rm -rf /'", semi);

    // embedded newline
    const newline = try shellQuote(alloc, "line1\nline2");
    defer alloc.free(newline);
    try testing.expectEqualStrings("'line1\nline2'", newline);

    // parentheses (subshell)
    const parens = try shellQuote(alloc, "(echo hi)");
    defer alloc.free(parens);
    try testing.expectEqualStrings("'(echo hi)'", parens);

    // heredoc marker
    const heredoc = try shellQuote(alloc, "<<EOF");
    defer alloc.free(heredoc);
    try testing.expectEqualStrings("'<<EOF'", heredoc);

    // no quoting needed -- plain word should still be quoted
    // (shellQuote is only called when shellNeedsQuoting returns true,
    // but verify it produces valid output anyway)
    const plain = try shellQuote(alloc, "hello");
    defer alloc.free(plain);
    try testing.expectEqualStrings("'hello'", plain);
}

test "isCtrlBackslash" {
    const expect = testing.expect;

    // Basic: ctrl only (modifier 5 = 1 + 4)
    try expect(isCtrlBackslash("\x1b[92;5u"));

    // Explicit press event type (:1)
    try expect(isCtrlBackslash("\x1b[92;5:1u"));

    // Repeat event (:2) -- user holding Ctrl+\
    try expect(isCtrlBackslash("\x1b[92;5:2u"));

    // Release event (:3) -- must NOT trigger detach
    try expect(!isCtrlBackslash("\x1b[92;5:3u"));

    // Lock modifiers: caps_lock (bit 6) changes modifier value
    // ctrl + caps_lock = 1 + (4 + 64) = 69
    try expect(isCtrlBackslash("\x1b[92;69u"));
    try expect(isCtrlBackslash("\x1b[92;69:1u"));
    try expect(!isCtrlBackslash("\x1b[92;69:3u"));

    // ctrl + num_lock = 1 + (4 + 128) = 133
    try expect(isCtrlBackslash("\x1b[92;133u"));

    // ctrl + caps_lock + num_lock = 1 + (4 + 64 + 128) = 197
    try expect(isCtrlBackslash("\x1b[92;197u"));

    // Combined intentional modifiers -- must NOT match (ctrl+\ is the
    // detach key, not ctrl+shift+\ or ctrl+alt+\)
    // ctrl + shift = 1 + (4 + 1) = 6
    try expect(!isCtrlBackslash("\x1b[92;6u"));

    // ctrl + alt = 1 + (4 + 2) = 7
    try expect(!isCtrlBackslash("\x1b[92;7u"));

    // ctrl + super = 1 + (4 + 8) = 13
    try expect(!isCtrlBackslash("\x1b[92;13u"));

    // ctrl + shift + caps_lock = 1 + (1 + 4 + 64) = 70 -- shift is intentional
    try expect(!isCtrlBackslash("\x1b[92;70u"));

    // ctrl + shift + num_lock = 1 + (1 + 4 + 128) = 134 -- shift is intentional
    try expect(!isCtrlBackslash("\x1b[92;134u"));

    // Modifier without ctrl bit -- must NOT match
    // shift only = 1 + 1 = 2
    try expect(!isCtrlBackslash("\x1b[92;1u"));
    try expect(!isCtrlBackslash("\x1b[92;2u"));

    // Alternate key sub-fields (report_alternates flag)
    // shifted key | (124): \x1b[92:124;5u
    try expect(isCtrlBackslash("\x1b[92:124;5u"));

    // base layout key only (non-US keyboard): \x1b[92::92;5u
    try expect(isCtrlBackslash("\x1b[92::92;5u"));

    // both shifted and base layout: \x1b[92:124:92;5u
    try expect(isCtrlBackslash("\x1b[92:124:92;5u"));

    // Alternate keys + lock modifiers + event type
    try expect(isCtrlBackslash("\x1b[92:124;69:1u"));
    try expect(!isCtrlBackslash("\x1b[92:124;69:3u"));

    // Text codepoints section (flag 0b10000) -- tolerated and skipped
    // Even though ctrl+\ text is typically empty, terminals may vary
    try expect(isCtrlBackslash("\x1b[92;5;28u"));
    try expect(isCtrlBackslash("\x1b[92;5;28:92u"));

    // Wrong key code -- must NOT match
    try expect(!isCtrlBackslash("\x1b[91;5u"));
    try expect(!isCtrlBackslash("\x1b[93;5u"));
    try expect(!isCtrlBackslash("\x1b[9;5u"));
    try expect(!isCtrlBackslash("\x1b[920;5u"));

    // Sequence embedded in larger buffer (e.g., preceded by other input)
    try expect(isCtrlBackslash("abc\x1b[92;5u"));
    try expect(isCtrlBackslash("\x1b[A\x1b[92;5u"));

    // Garbage / malformed inputs
    try expect(!isCtrlBackslash("garbage"));
    try expect(!isCtrlBackslash(""));
    try expect(!isCtrlBackslash("\x1b["));
    try expect(!isCtrlBackslash("\x1b[92"));
    try expect(!isCtrlBackslash("\x1b[92;"));
    try expect(!isCtrlBackslash("\x1b[92;u"));
    try expect(!isCtrlBackslash("\x1b[;5u"));

    // Other CSI u sequences that happen to contain '92' elsewhere
    try expect(!isCtrlBackslash("\x1b[65;92u"));
}

test "isCtrlBackslash xterm modifyOtherKeys" {
    const expect = std.testing.expect;

    // Basic: ctrl only (modifier 5 = 1 + 4), key 92 = '\'
    // Format: CSI 27 ; <mod> ; <key> ~
    try expect(isCtrlBackslash("\x1b[27;5;92~"));

    // Lock modifiers tolerated
    // ctrl + caps_lock = 1 + (4 + 64) = 69
    try expect(isCtrlBackslash("\x1b[27;69;92~"));
    // ctrl + num_lock = 1 + (4 + 128) = 133
    try expect(isCtrlBackslash("\x1b[27;133;92~"));
    // ctrl + caps_lock + num_lock = 1 + (4 + 64 + 128) = 197
    try expect(isCtrlBackslash("\x1b[27;197;92~"));

    // Combined intentional modifiers must NOT match
    // ctrl + shift = 1 + (4 + 1) = 6
    try expect(!isCtrlBackslash("\x1b[27;6;92~"));
    // ctrl + alt = 1 + (4 + 2) = 7
    try expect(!isCtrlBackslash("\x1b[27;7;92~"));
    // ctrl + super = 1 + (4 + 8) = 13
    try expect(!isCtrlBackslash("\x1b[27;13;92~"));
    // ctrl + shift + caps_lock = 1 + (1 + 4 + 64) = 70 -- shift is intentional
    try expect(!isCtrlBackslash("\x1b[27;70;92~"));
    // ctrl + shift + num_lock = 1 + (1 + 4 + 128) = 134 -- shift is intentional
    try expect(!isCtrlBackslash("\x1b[27;134;92~"));

    // Modifier without ctrl bit -- must NOT match
    try expect(!isCtrlBackslash("\x1b[27;1;92~"));
    try expect(!isCtrlBackslash("\x1b[27;2;92~"));

    // Wrong key code -- must NOT match
    try expect(!isCtrlBackslash("\x1b[27;5;91~"));
    try expect(!isCtrlBackslash("\x1b[27;5;93~"));
    try expect(!isCtrlBackslash("\x1b[27;5;65~"));

    // Wrong sentinel -- must NOT match
    try expect(!isCtrlBackslash("\x1b[28;5;92~"));
    try expect(!isCtrlBackslash("\x1b[26;5;92~"));

    // Wrong terminator -- must NOT match
    try expect(!isCtrlBackslash("\x1b[27;5;92u"));
    try expect(!isCtrlBackslash("\x1b[27;5;92m"));

    // CSI sequences that look similar but are not modifyOtherKeys
    try expect(!isCtrlBackslash("\x1b[27m")); // SGR reset reverse
    try expect(!isCtrlBackslash("\x1b[27~")); // xterm F4
    try expect(!isCtrlBackslash("\x1b[27;5R")); // truncated cursor report

    // Sequence embedded in larger buffer
    try expect(isCtrlBackslash("abc\x1b[27;5;92~"));
    try expect(isCtrlBackslash("\x1b[A\x1b[27;5;92~"));

    // Garbage / malformed
    try expect(!isCtrlBackslash("\x1b[27"));
    try expect(!isCtrlBackslash("\x1b[27;"));
    try expect(!isCtrlBackslash("\x1b[27;5"));
    try expect(!isCtrlBackslash("\x1b[27;5;"));
    try expect(!isCtrlBackslash("\x1b[27;5;92"));
}

test "isDetachKeyDisabled" {
    _ = cross.unsetenv("ZMX_NO_DETACH_KEY");
    try testing.expect(!isDetachKeyDisabled());

    _ = cross.setenv("ZMX_NO_DETACH_KEY", "1", 1);
    defer _ = cross.unsetenv("ZMX_NO_DETACH_KEY");
    try testing.expect(isDetachKeyDisabled());
}

test "stripAnsi: plain text passes through" {
    const alloc = testing.allocator;
    const result = try stripAnsi(alloc, "hello world\n");
    defer alloc.free(result);
    try testing.expectEqualStrings("hello world\n", result);
}

test "stripAnsi: removes SGR color codes" {
    const alloc = testing.allocator;
    // \e[31m = red, \e[0m = reset
    const result = try stripAnsi(alloc, "\x1b[31mred\x1b[0m");
    defer alloc.free(result);
    try testing.expectEqualStrings("red", result);
}

test "stripAnsi: removes cursor movement" {
    const alloc = testing.allocator;
    // \e[2J = clear screen, \e[H = home cursor
    const result = try stripAnsi(alloc, "\x1b[2J\x1b[Hhello");
    defer alloc.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "stripAnsi: preserves newlines and tabs" {
    const alloc = testing.allocator;
    const result = try stripAnsi(alloc, "line1\nline2\ttab\r");
    defer alloc.free(result);
    try testing.expectEqualStrings("line1\nline2\ttab\r", result);
}

test "stripAnsi: removes OSC sequences" {
    const alloc = testing.allocator;
    // OSC 0;title BEL = set window title
    const result = try stripAnsi(alloc, "\x1b]0;My Title\x07hello");
    defer alloc.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "stripAnsi: removes DA query and response" {
    const alloc = testing.allocator;
    // DA1 query: \e[c, DA1 response: \e[?62;22c
    const result = try stripAnsi(alloc, "\x1b[c\x1b[?62;22chello");
    defer alloc.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "stripAnsi: complex mixed content" {
    const alloc = testing.allocator;
    // Shell prompt with colors + command echo + output
    const input = "\x1b[0;32m[user@host ~]$\x1b[0m git log\n" ++
        "abc1234 commit message\n" ++
        "\x1b[0;32m[user@host ~]$\x1b[0m";
    const result = try stripAnsi(alloc, input);
    defer alloc.free(result);
    try testing.expectEqualStrings("[user@host ~]$ git log\nabc1234 commit message\n[user@host ~]$", result);
}

test "stripAnsi: empty input" {
    const alloc = testing.allocator;
    const result = try stripAnsi(alloc, "");
    defer alloc.free(result);
    try testing.expectEqualStrings("", result);
}

test "stripAnsi: only escape sequences" {
    const alloc = testing.allocator;
    const result = try stripAnsi(alloc, "\x1b[31m\x1b[1m\x1b[0m");
    defer alloc.free(result);
    try testing.expectEqualStrings("", result);
}

test "stripAnsi: keeps UTF-8 text" {
    const alloc = testing.allocator;
    const result = try stripAnsi(alloc, "\x1b[1mcafé\x1b[0m – 日本 🎉\n");
    defer alloc.free(result);
    try testing.expectEqualStrings("café – 日本 🎉\n", result);
}

test "stripAnsi: UTF-8 bytes do not start escape sequences" {
    const alloc = testing.allocator;
    // Ý is C3 9D, and 0x9D on its own is the 8-bit OSC introducer
    const result = try stripAnsi(alloc, "Ýmir\nline two\n");
    defer alloc.free(result);
    try testing.expectEqualStrings("Ýmir\nline two\n", result);
}
