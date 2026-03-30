const std = @import("std");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const socket = @import("socket.zig");
const testing = std.testing;

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

/// OSC 133;A (prompt start) marker.
const OSC_133_A = "\x1b]133;A";

/// Rewrite OSC 133;A sequences to include `redraw=0`, which tells the outer
/// terminal not to clear prompt lines on resize. This is necessary because
/// zmx sits between the shell and the outer terminal: from the outer terminal's
/// perspective, the foreground process (zmx client) cannot redraw prompts.
/// Without this, the outer terminal clears the prompt on resize expecting the
/// shell to redraw it, but the shell's redraw goes through zmx's IPC path with
/// cursor coordinates relative to the inner PTY, causing a cursor desync that
/// makes the prompt invisible.
/// See: https://github.com/neurosnap/zmx/issues/111
pub fn rewritePromptRedraw(alloc: std.mem.Allocator, data: []const u8) ?[]const u8 {
    // Quick scan: is there any OSC 133;A in this chunk?
    if (std.mem.indexOf(u8, data, OSC_133_A) == null) return null;

    var result = std.ArrayList(u8).initCapacity(alloc, data.len + 200) catch return null;
    errdefer result.deinit(alloc);
    result.appendSlice(alloc, data) catch return null;

    // Work backwards so index shifts don't invalidate later positions.
    var search_from: usize = result.items.len;
    while (search_from > 0) {
        const haystack = result.items[0..search_from];
        const pos = std.mem.lastIndexOf(u8, haystack, OSC_133_A) orelse break;
        search_from = pos;

        const after = pos + OSC_133_A.len;
        if (after >= result.items.len) continue;

        // Find the string terminator (BEL \x07 or ST \x1b\\).
        var term_pos: ?usize = null;
        var j = after;
        while (j < result.items.len) : (j += 1) {
            if (result.items[j] == '\x07') {
                term_pos = j;
                break;
            }
            if (result.items[j] == '\x1b' and j + 1 < result.items.len and result.items[j + 1] == '\\') {
                term_pos = j;
                break;
            }
        }
        const end = term_pos orelse continue;

        // Check the parameter region between OSC_133_A and the terminator.
        const params = result.items[after..end];

        // If redraw=0 already present, skip.
        if (std.mem.indexOf(u8, params, "redraw=0") != null) continue;

        // If redraw= exists with a different value, replace it.
        if (std.mem.indexOf(u8, params, "redraw=")) |rdw_offset| {
            const abs_rdw = after + rdw_offset;
            const value_start = abs_rdw + "redraw=".len;
            var value_end = value_start;
            while (value_end < end and result.items[value_end] != ';') : (value_end += 1) {}
            result.replaceRange(alloc, value_start, value_end - value_start, "0") catch return null;
            continue;
        }

        // No redraw= present. Insert ;redraw=0 before the terminator.
        result.replaceRange(alloc, end, 0, ";redraw=0") catch return null;
    }

    // If nothing changed, free and return null.
    if (std.mem.eql(u8, result.items, data)) {
        result.deinit(alloc);
        return null;
    }

    return result.toOwnedSlice(alloc) catch null;
}

test "rewritePromptRedraw: no OSC 133;A returns null" {
    const result = rewritePromptRedraw(std.testing.allocator, "hello world");
    try std.testing.expect(result == null);
}

test "rewritePromptRedraw: injects redraw=0 with BEL terminator" {
    const input = "\x1b]133;A\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b]133;A;redraw=0\x07", result);
}

test "rewritePromptRedraw: injects redraw=0 with ST terminator" {
    const input = "\x1b]133;A\x1b\\";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b]133;A;redraw=0\x1b\\", result);
}

test "rewritePromptRedraw: replaces existing redraw=1" {
    const input = "\x1b]133;A;redraw=1\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b]133;A;redraw=0\x07", result);
}

test "rewritePromptRedraw: replaces existing redraw=last" {
    const input = "\x1b]133;A;redraw=last\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b]133;A;redraw=0\x07", result);
}

test "rewritePromptRedraw: preserves redraw=0 (no-op)" {
    const result = rewritePromptRedraw(std.testing.allocator, "\x1b]133;A;redraw=0\x07");
    try std.testing.expect(result == null);
}

test "rewritePromptRedraw: preserves other parameters" {
    const input = "\x1b]133;A;aid=14;cl=line\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b]133;A;aid=14;cl=line;redraw=0\x07", result);
}

test "rewritePromptRedraw: handles multiple markers" {
    const input = "before\x1b]133;A\x07middle\x1b]133;A;redraw=1\x07after";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("before\x1b]133;A;redraw=0\x07middle\x1b]133;A;redraw=0\x07after", result);
}

test "rewritePromptRedraw: does not touch OSC 133;B or 133;C" {
    const input = "\x1b]133;B\x07\x1b]133;C\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input);
    try std.testing.expect(result == null);
}

test "rewritePromptRedraw: embedded in larger output" {
    const input = "some output\r\n\x1b]133;A\x07prompt$ \x1b]133;B\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("some output\r\n\x1b]133;A;redraw=0\x07prompt$ \x1b]133;B\x07", result);
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
pub fn isCtrlBackslash(buf: []const u8) bool {
    if (buf.len == 0) return false;
    return buf[0] == 0x1C or isKeyPressed(buf, 0x5c, 0b100);
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
    if (expected_mods > 0 and expected_mods != intentional_mods) return false;

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

/// Detect if the payload contains user input that should be printed to the screen or
/// is a key combination like up-arrow, backspace, enter, ctrl+f, etc.
pub fn isUserInput(payload: []const u8) bool {
    var parser = ghostty_vt.Parser.init();
    for (payload) |c| {
        const actions = parser.next(c);
        for (actions) |action_opt| {
            const action = action_opt orelse continue;
            switch (action) {
                .print => return true, // printable characters
                .csi_dispatch => |csi| {
                    // kitty keyboard: CSI ... u or CSI ... ~
                    // legacy modified keys: CSI 27 ; ... ~
                    // arrow/function keys with modifiers: CSI 1 ; <mod> A-D
                    if (csi.final == 'u' or csi.final == '~') return true;
                    // modified arrow keys (e.g., Ctrl+F sends CSI 1;5C in legacy mode)
                    if (csi.final >= 'A' and csi.final <= 'D' and csi.params.len > 1) return true;
                    // mouse events: CSI M (basic) or CSI < (SGR extended) - EXCLUDE these
                    // only intentional keyboard input should trigger leader switch
                    if (csi.final == 'M' or csi.final == '<') return false;
                    // focus events: CSI I (focus in) or CSI O (focus out) - EXCLUDE these
                    // these are automatic terminal events, not user typing
                    if (csi.final == 'I' or csi.final == 'O') return false;
                },
                .execute => |code| {
                    // looking for CR, LF, tab, and backspace
                    if (code == 0x0D or code == 0x0A or code == 0x09 or code == 0x08) return true;
                },
                else => {},
            }
        }
    }
    return false;
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
    }

    const pages = &term.screens.active.pages;
    const screen_top = pages.getTopLeft(.screen);
    const active_top = pages.getTopLeft(.active);
    const has_scrollback = !screen_top.eql(active_top);

    // Two-phase serialization to preserve scrollback without corrupting
    // cursor positions. This matters for nested zmx sessions (zmx→SSH→zmx)
    // where the outer daemon's ghostty-vt accumulates inner session scrollback.
    //
    // Phase 1: Emit scrollback content (plain text with styles, no terminal extras).
    // These lines scroll past the visible area into the terminal's scrollback buffer.
    // Phase 2: Clear visible screen, then emit visible content with full extras.
    // The clear ensures visible content starts from a clean slate regardless of
    // how much scrollback preceded it. CUP cursor positioning is then correct.
    //
    // See: https://github.com/neurosnap/zmx/issues/31

    // Phase 1: scrollback only (if any exists)
    if (has_scrollback) {
        if (active_top.up(1)) |sb_bottom_row| {
            var sb_bottom = sb_bottom_row;
            sb_bottom.x = @intCast(pages.cols - 1);

            var scroll_fmt = ghostty_vt.formatter.TerminalFormatter.init(term, .vt);
            scroll_fmt.content = .{
                .selection = ghostty_vt.Selection.init(
                    screen_top,
                    sb_bottom,
                    false,
                ),
            };
            scroll_fmt.extra = .none; // no modes, cursor, keyboard — just content
            scroll_fmt.format(&builder.writer) catch |err| {
                std.log.warn("failed to format scrollback err={s}", .{@errorName(err)});
            };
        }

        // Clear visible screen after scrollback. \x1b[2J clears only the visible
        // rows (not the scrollback buffer). \x1b[H homes the cursor. \x1b[0m resets
        // SGR style so phase 1 styles don't bleed into phase 2.
        builder.writer.writeAll("\x1b[2J\x1b[H\x1b[0m") catch {};
    }

    // Phase 2: visible screen with full extras (modes, cursor, keyboard, etc.)
    var vis_fmt = ghostty_vt.formatter.TerminalFormatter.init(term, .vt);

    // Restrict content to the active viewport only
    const active_tl = pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    const active_br = pages.pin(.{
        .active = .{
            .x = @intCast(pages.cols - 1),
            .y = @intCast(pages.rows - 1),
        },
    });

    if (active_tl != null and active_br != null) {
        vis_fmt.content = .{
            .selection = ghostty_vt.Selection.init(
                active_tl.?,
                active_br.?,
                false,
            ),
        };
    }
    // Fallback: if pins are somehow invalid, use null selection (all content)

    vis_fmt.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false, // tabstop restoration moves cursor after CUP, corrupting position
        .pwd = true,
        .keyboard = true,
        .screen = .all,
    };

    vis_fmt.format(&builder.writer) catch |err| {
        std.log.warn("failed to format terminal state err={s}", .{@errorName(err)});
        return null;
    };

    const output = builder.writer.buffered();
    if (output.len == 0) return null;

    // Restore the original synchronized_output mode before returning
    if (had_synchronized_output) {
        term.modes.set(.synchronized_output, true);
    }

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

test "serializeTerminalState excludes synchronized output replay" {
    const alloc = testing.allocator;

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

    try testing.expect(term.modes.get(.bracketed_paste));
    try testing.expect(term.modes.get(.synchronized_output));

    const output = serializeTerminalState(alloc, &term) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    // The serialized output should contain bracketed paste (DECSET 2004)
    // but NOT synchronized output (DECSET 2026)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[?2004h") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[?2026h") == null);
}

fn testCreateTerminal(alloc: std.mem.Allocator, cols: u16, rows: u16, vt_data: []const u8) !ghostty_vt.Terminal {
    var term = try ghostty_vt.Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = 10_000_000,
    });
    if (vt_data.len > 0) {
        var stream = term.vtStream();
        defer stream.deinit();
        try stream.nextSlice(vt_data);
    }
    return term;
}

fn expectScreensMatch(alloc: std.mem.Allocator, expected: *ghostty_vt.Terminal, actual: *ghostty_vt.Terminal) !void {
    const exp_str = try expected.plainString(alloc);
    defer alloc.free(exp_str);
    const act_str = try actual.plainString(alloc);
    defer alloc.free(act_str);
    try testing.expectEqualStrings(exp_str, act_str);
}

fn expectCursorAt(term: *ghostty_vt.Terminal, row: usize, col: usize) !void {
    const cursor = &term.screens.active.cursor;
    try testing.expectEqual(col, cursor.x);
    try testing.expectEqual(row, cursor.y);
}

fn serializeRoundtrip(alloc: std.mem.Allocator, source: *ghostty_vt.Terminal) !ghostty_vt.Terminal {
    const serialized = serializeTerminalState(alloc, source) orelse
        return error.SerializationFailed;
    defer alloc.free(serialized);

    var dest = try ghostty_vt.Terminal.init(alloc, .{
        .cols = source.screens.active.pages.cols,
        .rows = source.screens.active.pages.rows,
        .max_scrollback = 10_000_000,
    });
    var stream = dest.vtStream();
    defer stream.deinit();
    try stream.nextSlice(serialized);
    return dest;
}

fn expectMarkerAtRow(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal, marker: []const u8, expected_row: usize) !void {
    const plain = try term.plainString(alloc);
    defer alloc.free(plain);
    var row: usize = 0;
    var iter = std.mem.splitScalar(u8, plain, '\n');
    while (iter.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) != null) {
            try testing.expectEqual(expected_row, row);
            return;
        }
        row += 1;
    }
    std.debug.print("marker '{s}' not found in terminal output\n", .{marker});
    return error.TestExpectedEqual;
}

test "serializeTerminalState roundtrip preserves cursor position" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 80, 24, "\x1b[2J" ++ // clear
        "\x1b[10;20H" // cursor at row 10, col 20 (1-indexed)
    );
    defer term.deinit(alloc);

    try expectCursorAt(&term, 9, 19); // 0-indexed

    var client = try serializeRoundtrip(alloc, &term);
    defer client.deinit(alloc);

    try expectCursorAt(&client, 9, 19);
}

test "serializeTerminalState roundtrip preserves CUP-positioned markers" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 80, 24, "\x1b[2J" ++
        "\x1b[2;5HMARK_A" ++
        "\x1b[6;15HMARK_B" ++
        "\x1b[10;30HMARK_C" ++
        "\x1b[14;50HMARK_D" ++
        "\x1b[16;20H");
    defer term.deinit(alloc);

    var client = try serializeRoundtrip(alloc, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);
    try expectMarkerAtRow(alloc, &client, "MARK_A", 1);
    try expectMarkerAtRow(alloc, &client, "MARK_B", 5);
    try expectMarkerAtRow(alloc, &client, "MARK_C", 9);
    try expectMarkerAtRow(alloc, &client, "MARK_D", 13);
    try expectCursorAt(&client, 15, 19);
}

test "serializeTerminalState with scrollback preserves visible content" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 80, 24, "");
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    // Generate 80 lines of scrollback (more than 24 visible rows)
    var buf: [32]u8 = undefined;
    for (0..80) |i| {
        const line = std.fmt.bufPrint(&buf, "SCROLL_{d}\r\n", .{i}) catch unreachable;
        try stream.nextSlice(line);
    }

    // Clear screen and place markers at specific positions
    try stream.nextSlice("\x1b[2J" ++
        "\x1b[2;5HMARK_A" ++
        "\x1b[6;15HMARK_B" ++
        "\x1b[10;30HMARK_C" ++
        "\x1b[16;20H");

    // Verify source terminal has scrollback
    const pages = &term.screens.active.pages;
    const has_scrollback = !pages.getTopLeft(.screen).eql(pages.getTopLeft(.active));
    try testing.expect(has_scrollback);

    // Roundtrip: serialize → feed into fresh terminal
    var client = try serializeRoundtrip(alloc, &term);
    defer client.deinit(alloc);

    // Visible content must match (this is the core cursor corruption test)
    try expectScreensMatch(alloc, &term, &client);
    try expectMarkerAtRow(alloc, &client, "MARK_A", 1);
    try expectMarkerAtRow(alloc, &client, "MARK_B", 5);
    try expectMarkerAtRow(alloc, &client, "MARK_C", 9);
    try expectCursorAt(&client, 15, 19);
}

test "serializeTerminalState nested roundtrip preserves content" {
    // Simulates: inner zmx → serialized state → outer ghostty-vt → serialized again → client
    // This is the exact nested session scenario (zmx → SSH → zmx).
    const alloc = testing.allocator;

    // "Inner" terminal with scrollback + markers
    var inner = try testCreateTerminal(alloc, 80, 24, "");
    defer inner.deinit(alloc);

    {
        var inner_stream = inner.vtStream();
        defer inner_stream.deinit();
        var buf: [32]u8 = undefined;
        for (0..60) |i| {
            const line = std.fmt.bufPrint(&buf, "SCROLL_{d}\r\n", .{i}) catch unreachable;
            try inner_stream.nextSlice(line);
        }
        try inner_stream.nextSlice("\x1b[2J" ++
            "\x1b[3;10HINNER_A" ++
            "\x1b[12;25HINNER_B" ++
            "\x1b[20;5H");
    }

    // Record inner's ground truth
    const inner_cursor_x = inner.screens.active.cursor.x;
    const inner_cursor_y = inner.screens.active.cursor.y;

    // Serialize inner (simulates inner daemon re-attach to inner client)
    const inner_serialized = serializeTerminalState(alloc, &inner) orelse
        return error.SerializationFailed;
    defer alloc.free(inner_serialized);

    // "Outer" terminal processes inner's serialized output
    var outer = try testCreateTerminal(alloc, 80, 24, "");
    defer outer.deinit(alloc);

    {
        var outer_stream = outer.vtStream();
        defer outer_stream.deinit();
        try outer_stream.nextSlice(inner_serialized);
    }

    // Serialize outer (simulates outer daemon re-attach after detach)
    var client = try serializeRoundtrip(alloc, &outer);
    defer client.deinit(alloc);

    // Client must see the same content as inner's visible screen
    try expectScreensMatch(alloc, &inner, &client);
    try expectCursorAt(&client, inner_cursor_y, inner_cursor_x);
    try expectMarkerAtRow(alloc, &client, "INNER_A", 2);
    try expectMarkerAtRow(alloc, &client, "INNER_B", 11);
}

test "serializeTerminalState alternate screen not leaked" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 80, 24, "\x1b[?1049h" ++ // enter alt screen
        "\x1b[2J\x1b[3;10HALT_MARK" ++ // write on alt screen
        "\x1b[?1049l" ++ // exit alt screen
        "\x1b[2J\x1b[2;5HMAIN_MARK\x1b[8;20H" // write on main screen
    );
    defer term.deinit(alloc);

    var client = try serializeRoundtrip(alloc, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);

    const plain = try client.plainString(alloc);
    defer alloc.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "ALT_MARK") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "MAIN_MARK") != null);
}

test "serializeTerminalState size mismatch roundtrip" {
    const alloc = testing.allocator;

    var term = try testCreateTerminal(alloc, 80, 30, "\x1b[2J" ++
        "\x1b[3;10HSIZE_A" ++
        "\x1b[12;20HSIZE_B" ++
        "\x1b[20;40HSIZE_C" ++
        "\x1b[15;15H");
    defer term.deinit(alloc);

    // Resize to 24 rows (simulates outer terminal being smaller)
    try term.resize(alloc, 80, 24);

    var client = try serializeRoundtrip(alloc, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);
    try expectCursorAt(&client, term.screens.active.cursor.y, term.screens.active.cursor.x);
}

test "serializeTerminalState scrollback + size mismatch nested roundtrip" {
    const alloc = testing.allocator;

    var inner = try testCreateTerminal(alloc, 80, 30, "");
    defer inner.deinit(alloc);

    {
        var inner_stream = inner.vtStream();
        defer inner_stream.deinit();
        var buf: [32]u8 = undefined;
        for (0..80) |i| {
            const line = std.fmt.bufPrint(&buf, "LINE_{d}\r\n", .{i}) catch unreachable;
            try inner_stream.nextSlice(line);
        }
        try inner_stream.nextSlice("\x1b[2J" ++
            "\x1b[3;10HSTRESS_A" ++
            "\x1b[12;25HSTRESS_B" ++
            "\x1b[16;20H");
    }

    // Resize inner to 24 rows (outer terminal is smaller)
    try inner.resize(alloc, 80, 24);

    const inner_cursor_x = inner.screens.active.cursor.x;
    const inner_cursor_y = inner.screens.active.cursor.y;

    // Inner serialize → outer processes → outer serialize → client
    const inner_ser = serializeTerminalState(alloc, &inner) orelse
        return error.SerializationFailed;
    defer alloc.free(inner_ser);

    var outer = try testCreateTerminal(alloc, 80, 24, "");
    defer outer.deinit(alloc);
    {
        var outer_stream = outer.vtStream();
        defer outer_stream.deinit();
        try outer_stream.nextSlice(inner_ser);
    }

    var client = try serializeRoundtrip(alloc, &outer);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &inner, &client);
    try expectCursorAt(&client, inner_cursor_y, inner_cursor_x);
}

test "isUserInput: printable characters" {
    // Regular text should be detected as user input
    try testing.expect(isUserInput("hello"));
    try testing.expect(isUserInput("Hello World!"));
    try testing.expect(isUserInput("12345"));
    try testing.expect(isUserInput("!@#$%^&*()"));
}

test "isUserInput: whitespace characters" {
    // Space character is printable
    try testing.expect(isUserInput(" "));
    try testing.expect(isUserInput("   "));
}

test "isUserInput: line feed (LF)" {
    // LF triggers .execute action
    try testing.expect(isUserInput("\n"));
    try testing.expect(isUserInput("test\n"));
}

test "isUserInput: carriage return (CR)" {
    // CR triggers .execute action
    try testing.expect(isUserInput("\r"));
    try testing.expect(isUserInput("test\r"));
}

test "isUserInput: tab" {
    // Tab triggers .execute action
    try testing.expect(isUserInput("\t"));
    try testing.expect(isUserInput("col1\tcol2"));
}

test "isUserInput: backspace" {
    // Backspace triggers .execute action
    try testing.expect(isUserInput("\x08"));
    try testing.expect(isUserInput("test\x08"));
}

test "isUserInput: arrow keys (CSI ~)" {
    // Arrow keys use CSI with ~ - these have params
    try testing.expect(isUserInput("\x1b[3~")); // delete
    try testing.expect(isUserInput("\x1b[5~")); // page up
    try testing.expect(isUserInput("\x1b[6~")); // page down
}

test "isUserInput: modified arrow keys with CSI u" {
    // Modified arrow keys with CSI ... u
    try testing.expect(isUserInput("\x1bOA")); // up with modifier
    try testing.expect(isUserInput("\x1bOB")); // down with modifier
    try testing.expect(isUserInput("\x1bOC")); // right with modifier
    try testing.expect(isUserInput("\x1bOD")); // left with modifier
}

test "isUserInput: up arrow legacy" {
    // Legacy up arrow: CSI A (with params for kitty-style)
    try testing.expect(isUserInput("\x1b[1;1A")); // kitty-style legacy
}

test "isUserInput: up arrow kitty" {
    // Kitty keyboard up arrow: CSI 1;1;1A (no colon format supported by parser)
    try testing.expect(isUserInput("\x1b[1;1;1A")); // kitty up arrow
}

test "isUserInput: arrow keys with modifier params CSI A-D" {
    // Modified arrow keys like Ctrl+Up: CSI 1;5A
    try testing.expect(isUserInput("\x1b[1;5A")); // Ctrl+Up
    try testing.expect(isUserInput("\x1b[1;5B")); // Ctrl+Down
    try testing.expect(isUserInput("\x1b[1;5C")); // Ctrl+Right
    try testing.expect(isUserInput("\x1b[1;5D")); // Ctrl+Left
    try testing.expect(isUserInput("\x1b[1;3A")); // Alt+Up
    try testing.expect(isUserInput("\x1b[1;3B")); // Alt+Down
}

test "isUserInput: function keys with modifiers CSI 27 ; ~" {
    // Legacy modified keys: CSI 27 ; ... ~
    try testing.expect(isUserInput("\x1b[15;2~")); // F4 with modifier
    try testing.expect(isUserInput("\x1b[17;2~")); // F5 with modifier
    try testing.expect(isUserInput("\x1b[18;2~")); // F6 with modifier
}

test "isUserInput: enter key" {
    // Enter is LF (0x0A)
    try testing.expect(isUserInput("\x0A"));
}

test "isUserInput: mixed content" {
    // Mix of printable and control sequences
    try testing.expect(isUserInput("hello\nworld"));
    try testing.expect(isUserInput("\x1b[3~\x1b[6~")); // multiple CSI ~ sequences
    try testing.expect(isUserInput("abc\x1b[3~def")); // text with CSI ~
}

test "isUserInput: non-user input (escape sequences only)" {
    // Cursor movement without user input
    try testing.expect(!isUserInput("\x1b[2;1H")); // CSI H cursor home
    // SGR color set (no printing)
    try testing.expect(!isUserInput("\x1b[0m"));
    // Cursor position report query
    try testing.expect(!isUserInput("\x1b[6n"));
}

test "isUserInput: empty string" {
    try testing.expect(!isUserInput(""));
}

test "isUserInput: only whitespace controls" {
    // Multiple control chars should return true
    try testing.expect(isUserInput("\n\r\t"));
}

test "isUserInput: kitty keyboard sequences" {
    // Kitty keyboard protocol uses CSI u
    try testing.expect(isUserInput("\x1b[11;2u")); // F1 with modifier
    try testing.expect(isUserInput("\x1b[12;2u")); // F2 with modifier
}

test "isUserInput: mouse events (CSI M) excluded" {
    // Basic mouse tracking (SGR disabled): CSI M Cb Cx Cy
    // Mouse events should NOT trigger leader switch
    try testing.expect(!isUserInput("\x1b[M@ 0 0")); // button 0, pos 0,0
    try testing.expect(!isUserInput("\x1b[M@ 1 1")); // button 1, pos 1,1
}

test "isUserInput: mouse events SGR mode CSI < excluded" {
    // SGR extended mouse tracking: CSI < Cb;Cx;Y M
    // Mouse events should NOT trigger leader switch
    try testing.expect(!isUserInput("\x1b[<0;1;1M")); // button release
    try testing.expect(!isUserInput("\x1b[<64;1;1M")); // button press
}

test "isUserInput: focus events excluded" {
    // Focus in/out are automatic terminal events, not user typing
    try testing.expect(!isUserInput("\x1b[I")); // focus in
    try testing.expect(!isUserInput("\x1b[O")); // focus out
}

test "isUserInput: bracketed paste included" {
    // Bracketed paste start/end are user-initiated paste operations
    try testing.expect(isUserInput("\x1b[200~")); // paste start
    try testing.expect(isUserInput("\x1b[201~")); // paste end
    // Content between start/end is also user input
    try testing.expect(isUserInput("\x1b[200~hello\x1b[201~"));
}
