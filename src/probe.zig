//! Outer terminal probing and snapshot generation for zmx.
//!
//! Synchronizes the outer terminal emulator's configuration (colors, palette,
//! cursor style, blinking, pixel geometry, protocol capabilities, and DEC modes
//! such as in-band size reports) into a binary Snapshot buffer.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const lib_posix = @import("posix.zig");
const cross = @import("cross.zig");
const ipc = @import("ipc.zig");
const snapshot = @import("snapshot.zig");
const Allocator = std.mem.Allocator;

/// Escape sequences sent to probe the outer terminal.
///
/// Combines:
/// - Dynamic colors: OSC 10 (fg), OSC 11 (bg), OSC 12 (cursor)
/// - 16-color ANSI palette: OSC 4 (0..15)
/// - Cursor shape: DECSCUSR query (\x1b[? q)
/// - Cursor blinking: DECRQM mode 12 (\x1b[?12$p)
/// - In-band size reports: DECRQM mode 2048 (\x1b[?2048$p)
/// - Color scheme / dark-light mode: DECRQM mode 2031 (\x1b[?2031$p)
/// - Pixel geometry: XTWINOPS text area (\x1b[14t)
/// - Kitty keyboard protocol query (\x1b[?u)
pub const PROBE_QUERY =
    "\x1b]10;?\x07" ++
    "\x1b]11;?\x07" ++
    "\x1b]12;?\x07" ++
    "\x1b]4;0;?;1;?;2;?;3;?;4;?;5;?;6;?;7;?;8;?;9;?;10;?;11;?;12;?;13;?;14;?;15;?\x07" ++
    "\x1b[? q" ++
    "\x1b[?12$p" ++
    "\x1b[?2048$p" ++
    "\x1b[?2031$p" ++
    "\x1b[14t" ++
    "\x1b[?u";

/// Default probe timeout in milliseconds for local TTYs.
pub const DEFAULT_PROBE_TIMEOUT_MS: u32 = 40;

fn getMonotonicNs() i128 {
    var ts: cross.c.struct_timespec = undefined;
    _ = cross.c.clock_gettime(cross.c.CLOCK_MONOTONIC, &ts);
    return @as(i128, ts.tv_sec) * std.time.ns_per_s + ts.tv_nsec;
}

/// Drains probe responses from tty_in_fd into the terminal's vtStream.
pub fn probeOuterTerminal(
    tty_out_fd: i32,
    tty_in_fd: i32,
    timeout_ms: u32,
    term: *ghostty_vt.Terminal,
) !void {
    _ = lib_posix.write(tty_out_fd, PROBE_QUERY) catch return;

    var vt_stream = term.vtStream();
    defer vt_stream.deinit();

    var poll_fds = [_]lib_posix.pollfd{.{
        .fd = tty_in_fd,
        .events = lib_posix.POLL.IN,
        .revents = 0,
    }};

    const start_ns = getMonotonicNs();
    const timeout_ns = @as(i128, timeout_ms) * std.time.ns_per_ms;

    var buf: [4096]u8 = undefined;

    while (true) {
        const elapsed_ns = getMonotonicNs() - start_ns;
        if (elapsed_ns >= timeout_ns) break;
        const remaining_ms = @as(i32, @intCast(@min(50, @divTrunc(timeout_ns - elapsed_ns, std.time.ns_per_ms))));
        if (remaining_ms <= 0) break;

        const poll_res = lib_posix.poll(&poll_fds, remaining_ms) catch break;
        if (poll_res == 0) break; // Timeout on slice

        if (poll_fds[0].revents & lib_posix.POLL.IN != 0) {
            const n = lib_posix.read(tty_in_fd, &buf) catch |err| {
                if (err == error.WouldBlock) continue;
                break;
            };
            if (n == 0) break;

            const slice = buf[0..n];
            applyProbeChunk(term, &vt_stream, slice);
        } else {
            break;
        }
    }
}

/// Ingest a slice of probe response bytes into the terminal and handle any non-OSC
/// response side-effects (DECRPM, XTWINOPS, Kitty keyboard).
pub fn applyProbeChunk(
    term: *ghostty_vt.Terminal,
    vt_stream: *ghostty_vt.TerminalStream,
    slice: []const u8,
) void {
    // Feed through Ghostty VT stream to parse OSC 4/10/11/12, DECSCUSR, etc.
    vt_stream.nextSlice(slice);

    // Parse DECRPM responses: \x1b[?<mode>;<status>$y (DEC) or \x1b[<mode>;<status>$y (ANSI)
    var decrpm_idx: usize = 0;
    while (std.mem.indexOfPos(u8, slice, decrpm_idx, "\x1b[")) |start_idx| {
        const rest = slice[start_idx + 2 ..];
        if (std.mem.indexOf(u8, rest, "$y")) |y_rel| {
            const report_str = rest[0..y_rel];
            const is_dec = report_str.len > 0 and report_str[0] == '?';
            const num_str = if (is_dec) report_str[1..] else report_str;
            if (std.mem.indexOfScalar(u8, num_str, ';')) |semi_rel| {
                const mode_raw = num_str[0..semi_rel];
                const status_raw = num_str[semi_rel + 1 ..];
                const mode_num = std.fmt.parseInt(u16, mode_raw, 10) catch 0;
                const status = std.fmt.parseInt(u8, status_raw, 10) catch 0;
                if (ghostty_vt.modes.modeFromInt(mode_num, !is_dec)) |mode| {
                    if (status == 1) {
                        term.modes.set(mode, true);
                    } else if (status == 2) {
                        term.modes.set(mode, false);
                    }
                }
            }
            decrpm_idx = start_idx + 2 + y_rel + 2;
        } else {
            break;
        }
    }

    // Parse XTWINOPS response: \x1b[4;<height>;<width>t
    var search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, slice, search_idx, "\x1b[4;")) |start_idx| {
        const rest = slice[start_idx + 4 ..];
        if (std.mem.indexOfScalar(u8, rest, 't')) |end_rel| {
            const param_str = rest[0..end_rel];
            if (std.mem.indexOfScalar(u8, param_str, ';')) |semi_idx| {
                const h_str = param_str[0..semi_idx];
                const w_str = param_str[semi_idx + 1 ..];
                const h = std.fmt.parseInt(u32, h_str, 10) catch 0;
                const w = std.fmt.parseInt(u32, w_str, 10) catch 0;
                if (h > 0 and w > 0) {
                    term.height_px = h;
                    term.width_px = w;
                }
            }
            search_idx = start_idx + 4 + end_rel + 1;
        } else {
            break;
        }
    }

    // Parse Kitty keyboard query response: \x1b[?<flags>u
    var kb_search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, slice, kb_search_idx, "\x1b[?")) |start_idx| {
        const rest = slice[start_idx + 3 ..];
        if (std.mem.indexOfScalar(u8, rest, 'u')) |end_rel| {
            const flag_str = rest[0..end_rel];
            if (std.fmt.parseInt(u5, flag_str, 10)) |flag_val| {
                term.screens.active.kitty_keyboard.set(
                    .set,
                    @as(ghostty_vt.kitty.KeyFlags, @bitCast(flag_val)),
                );
            } else |_| {}
            kb_search_idx = start_idx + 3 + end_rel + 1;
        } else {
            break;
        }
    }
}

/// Probes outer terminal if in TTY mode and encodes a binary Snapshot buffer.
pub fn probeAndSnapshot(
    io: std.Io,
    alloc: Allocator,
    rows: u16,
    cols: u16,
    xpixel: u16,
    ypixel: u16,
    is_tty: bool,
    timeout_ms: u32,
) ![]u8 {
    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = cols,
        .rows = rows,
    });
    defer term.deinit(alloc);

    term.width_px = xpixel;
    term.height_px = ypixel;

    if (is_tty) {
        probeOuterTerminal(
            lib_posix.STDOUT_FILENO,
            lib_posix.STDIN_FILENO,
            timeout_ms,
            &term,
        ) catch |err| {
            std.log.debug("probe outer terminal failed: {s}", .{@errorName(err)});
        };
    }

    var snap_buf: std.Io.Writer.Allocating = .init(alloc);
    defer snap_buf.deinit();

    try snapshot.exportSnapshot(alloc, &snap_buf.writer, &term, .{});
    return alloc.dupe(u8, snap_buf.written());
}

test "applyProbeChunk parses OSC colors, dec modes, and kitty protocols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try ghostty_vt.Terminal.init(testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);

    var vt_stream = term.vtStream();
    defer vt_stream.deinit();

    // Responses from outer terminal
    const osc_fg = "\x1b]10;rgb:c0c0/caf5/f5f5\x1b\\";
    const osc_bg = "\x1b]11;rgb:1a1a/1b1b/2626\x1b\\";
    const osc_cursor = "\x1b]12;rgb:ffff/aaaa/5555\x07";
    const osc_palette = "\x1b]4;0;rgb:1515/1616/1e1e;1;rgb:f7f7/7676/8e8e\x1b\\";
    const decscusr = "\x1b[5 q"; // Blinking bar
    const dec_in_band = "\x1b[?2048;1$y"; // In-band size reports enabled
    const dec_color_scheme = "\x1b[?2031;1$y"; // Report color scheme enabled
    const xtwinops = "\x1b[4;900;1440t";
    const kitty_kb = "\x1b[?1u";
    const kitty_gfx = "\x1b_Gi=1;OK\x1b\\";

    applyProbeChunk(&term, &vt_stream, osc_fg);
    applyProbeChunk(&term, &vt_stream, osc_bg);
    applyProbeChunk(&term, &vt_stream, osc_cursor);
    applyProbeChunk(&term, &vt_stream, osc_palette);
    applyProbeChunk(&term, &vt_stream, decscusr);
    applyProbeChunk(&term, &vt_stream, dec_in_band);
    applyProbeChunk(&term, &vt_stream, dec_color_scheme);
    applyProbeChunk(&term, &vt_stream, xtwinops);
    applyProbeChunk(&term, &vt_stream, kitty_kb);
    applyProbeChunk(&term, &vt_stream, kitty_gfx);

    const fg = term.colors.foreground.get().?;
    try testing.expectEqual(@as(u8, 0xc0), fg.r);
    try testing.expectEqual(@as(u8, 0xca), fg.g);
    try testing.expectEqual(@as(u8, 0xf5), fg.b);

    const bg = term.colors.background.get().?;
    try testing.expectEqual(@as(u8, 0x1a), bg.r);
    try testing.expectEqual(@as(u8, 0x1b), bg.g);
    try testing.expectEqual(@as(u8, 0x26), bg.b);

    const cursor = term.colors.cursor.get().?;
    try testing.expectEqual(@as(u8, 0xff), cursor.r);
    try testing.expectEqual(@as(u8, 0xaa), cursor.g);
    try testing.expectEqual(@as(u8, 0x55), cursor.b);

    const p0 = term.colors.palette.current[0];
    try testing.expectEqual(@as(u8, 0x15), p0.r);
    try testing.expectEqual(@as(u8, 0x16), p0.g);
    try testing.expectEqual(@as(u8, 0x1e), p0.b);

    const p1 = term.colors.palette.current[1];
    try testing.expectEqual(@as(u8, 0xf7), p1.r);
    try testing.expectEqual(@as(u8, 0x76), p1.g);
    try testing.expectEqual(@as(u8, 0x8e), p1.b);

    try testing.expectEqual(ghostty_vt.Screen.CursorStyle.bar, term.screens.active.cursor.cursor_style);
    try testing.expect(term.modes.get(.cursor_blinking));
    try testing.expect(term.modes.get(.in_band_size_reports));
    try testing.expect(term.modes.get(.report_color_scheme));
    try testing.expectEqual(@as(u32, 1440), term.width_px);
    try testing.expectEqual(@as(u32, 900), term.height_px);
    try testing.expectEqual(@as(u8, 1), term.screens.active.kitty_keyboard.current().int());
}

test "probe snapshot roundtrip preserves probed state and modes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term = try ghostty_vt.Terminal.init(testing.io, alloc, .{ .cols = 100, .rows = 30 });
    defer term.deinit(alloc);

    var vt_stream = term.vtStream();
    defer vt_stream.deinit();

    applyProbeChunk(&term, &vt_stream, "\x1b]10;rgb:aabb/ccdd/eeff\x1b\\");
    applyProbeChunk(&term, &vt_stream, "\x1b]11;rgb:1122/3344/5566\x1b\\");
    applyProbeChunk(&term, &vt_stream, "\x1b[3 q"); // Blinking underline
    applyProbeChunk(&term, &vt_stream, "\x1b[?2048;1$y"); // In-band size reports
    applyProbeChunk(&term, &vt_stream, "\x1b[4;600;800t");
    applyProbeChunk(&term, &vt_stream, "\x1b[?3u"); // Kitty keyboard flags = 3

    var snap_buf: std.Io.Writer.Allocating = .init(alloc);
    defer snap_buf.deinit();
    try snapshot.exportSnapshot(alloc, &snap_buf.writer, &term, .{});

    var reader: std.Io.Reader = .fixed(snap_buf.written());
    var import_res = try snapshot.startImport(alloc, testing.io, &reader, 1024 * 1024);
    defer import_res.deinit(alloc);

    var restored = import_res.terminal;
    defer restored.deinit(alloc);

    try testing.expectEqual(@as(u16, 100), restored.cols);
    try testing.expectEqual(@as(u16, 30), restored.rows);
    try testing.expectEqual(@as(u32, 800), restored.width_px);
    try testing.expectEqual(@as(u32, 600), restored.height_px);

    const fg = restored.colors.foreground.get().?;
    try testing.expectEqual(@as(u8, 0xaa), fg.r);
    try testing.expectEqual(@as(u8, 0xcc), fg.g);
    try testing.expectEqual(@as(u8, 0xee), fg.b);

    const bg = restored.colors.background.get().?;
    try testing.expectEqual(@as(u8, 0x11), bg.r);
    try testing.expectEqual(@as(u8, 0x33), bg.g);
    try testing.expectEqual(@as(u8, 0x55), bg.b);

    try testing.expectEqual(ghostty_vt.Screen.CursorStyle.underline, restored.screens.active.cursor.cursor_style);
    try testing.expect(restored.modes.get(.cursor_blinking));
    try testing.expect(restored.modes.get(.in_band_size_reports));
    try testing.expectEqual(@as(u8, 3), restored.screens.active.kitty_keyboard.current().int());
}
