const std = @import("std");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const util = @import("util.zig");
const cross = @import("cross");
const socket = @import("socket.zig");
const label = @import("label.zig");
const lib_posix = @import("posix.zig");
const Cfg = @import("cfg.zig");
const signal = @import("signal.zig");
const assert = std.debug.assert;
const daemonize = @import("daemonize.zig");
const builtin = @import("builtin");
const terminal = @import("terminal.zig");
const ghostty_vt = terminal.ghostty_vt;

/// clientLoop sends ipc commands to its corresponding daemon.  It uses poll() as its non-blocking
/// mechanism. It will send stdin to the daemon and receive stdout from the daemon.
pub fn clientLoop(client_sock_fd: i32, env_str: []const u8) !ClientResult {
    return clientLoopWithFds(client_sock_fd, env_str, lib_posix.STDIN_FILENO, lib_posix.STDOUT_FILENO);
}

fn clientLoopWithFds(client_sock_fd: i32, env_str: []const u8, stdin_fd: i32, stdout_fd: i32) !ClientResult {
    std.log.info("client loop fd={d}", .{client_sock_fd});
    const gpa: std.mem.Allocator = blk: {
        if (builtin.mode == .debug) {
            const GPA = std.heap.DebugAllocator(.{});
            const Static = struct {
                var gpa: GPA = .{};
            };
            break :blk Static.gpa.allocator();
        }
        break :blk std.heap.c_allocator;
    };
    defer lib_posix.close(client_sock_fd);

    try signal.openSignalPipe();
    defer signal.closeSignalPipe();
    signal.installWakeHandler(@backingInt(lib_posix.SIG.WINCH));
    signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
    signal.installWakeHandler(@backingInt(lib_posix.SIG.HUP));
    signal.installWakeHandler(@backingInt(lib_posix.SIG.INT));

    // Make socket non-blocking to avoid blocking on writes
    var sock_flags = try lib_posix.fcntl(client_sock_fd, lib_posix.F.GETFL, 0);
    sock_flags |= lib_posix.O_NONBLOCK;
    _ = try lib_posix.fcntl(client_sock_fd, lib_posix.F.SETFL, sock_flags);

    // Buffer for outgoing socket writes
    var sock_write_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer sock_write_buf.deinit(gpa);

    if (env_str.len > 0) {
        try ipc.appendMessage(gpa, &sock_write_buf, .EnvSet, env_str);
    }

    // Send init message with terminal size (buffered)
    const size = ipc.getTerminalSize(stdout_fd);
    try ipc.appendMessage(gpa, &sock_write_buf, .Init, std.mem.asBytes(&size));

    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(gpa, 4);
    defer poll_fds.deinit(gpa);

    var read_buf = try ipc.SocketBuffer.init(gpa);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer stdout_buf.deinit(gpa);

    // Make stdin non-blocking. O_NONBLOCK is set on the open file description,
    // which is shared with the parent shell; restore on exit to avoid
    // corrupting the parent's stdin.
    const stdin_orig_flags = try lib_posix.fcntl(stdin_fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(stdin_fd, lib_posix.F.SETFL, stdin_orig_flags | lib_posix.O_NONBLOCK);
    defer _ = lib_posix.fcntl(stdin_fd, lib_posix.F.SETFL, stdin_orig_flags) catch {};

    const detach_key_disabled = util.isDetachKeyDisabled();

    while (true) {
        poll_fds.clearRetainingCapacity();

        try poll_fds.append(gpa, .{
            .fd = stdin_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        });

        // Poll socket for read, and also for write if we have pending data
        var sock_events: i16 = lib_posix.POLL.IN;
        if (sock_write_buf.items.len > 0) {
            sock_events |= lib_posix.POLL.OUT;
        }
        try poll_fds.append(gpa, .{
            .fd = client_sock_fd,
            .events = sock_events,
            .revents = 0,
        });

        try poll_fds.append(gpa, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });

        if (stdout_buf.items.len > 0) {
            try poll_fds.append(gpa, .{
                .fd = stdout_fd,
                .events = lib_posix.POLL.OUT,
                .revents = 0,
            });
        }

        _ = try lib_posix.poll(poll_fds.items, -1);

        // The daemon is gone: what it queued is read and written by finishSession alone, bounded.
        if (poll_fds.items[1].revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
            std.log.info("poll hup|err|nval", .{});
            finishSession(gpa, client_sock_fd, stdout_fd, &read_buf, &stdout_buf);
            return ClientResult{ .kind = .detach, .session_name = null };
        }

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            try signal.drainSignalPipe();
            const next_size = ipc.getTerminalSize(stdout_fd);
            try ipc.appendMessage(
                gpa,
                &sock_write_buf,
                .Resize,
                std.mem.asBytes(&next_size),
            );
        }

        // Handle stdin -> socket (Input)
        const inp_flags = (lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL);
        if (poll_fds.items[0].revents & inp_flags != 0) {
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = lib_posix.read(stdin_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                return err;
            };

            if (n_opt) |n| {
                if (n > 0) {
                    // Check for detach sequences (ctrl+\ as first byte or Kitty escape sequence)
                    if (!detach_key_disabled and util.isCtrlBackslash(buf[0..n])) {
                        std.log.info("detach key detected", .{});
                        try ipc.appendMessage(gpa, &sock_write_buf, .Detach, "");
                    } else {
                        try ipc.appendMessage(gpa, &sock_write_buf, .Input, buf[0..n]);
                    }
                } else {
                    std.log.info("eof stdin", .{});
                    // EOF on stdin
                    return ClientResult{ .kind = .detach, .session_name = null };
                }
            }
        }

        // Handle socket read (incoming Output messages from daemon)
        if (poll_fds.items[1].revents & lib_posix.POLL.IN != 0) {
            const n = read_buf.read(client_sock_fd) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    finishSession(gpa, client_sock_fd, stdout_fd, &read_buf, &stdout_buf);
                    return ClientResult{ .kind = .detach, .session_name = null };
                }
                std.log.err("daemon read err={s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) {
                std.log.info("server closed connection", .{});
                finishSession(gpa, client_sock_fd, stdout_fd, &read_buf, &stdout_buf);
                return ClientResult{ .kind = .detach, .session_name = null };
            }

            while (read_buf.next()) |msg| {
                switch (msg.header.tag) {
                    .Output => {
                        if (msg.payload.len > 0) {
                            try stdout_buf.appendSlice(gpa, msg.payload);
                        }
                    },
                    .Resize => {
                        // daemon is asking for the client's window size usually in response
                        // to this client being set as leader.
                        const next_size = ipc.getTerminalSize(stdout_fd);
                        try ipc.appendMessage(
                            gpa,
                            &sock_write_buf,
                            .Resize,
                            std.mem.asBytes(&next_size),
                        );
                    },
                    .Switch => {
                        std.log.info("switch session", .{});
                        // Payload format: "session_name\ncwd" from the daemon
                        const newline_idx = std.mem.indexOfScalar(u8, msg.payload, '\n') orelse {
                            // No cwd provided (backward compat or old daemon)
                            return ClientResult{ .kind = .switch_session, .session_name = try gpa.dupe(u8, msg.payload) };
                        };
                        return ClientResult{
                            .kind = .switch_session,
                            .session_name = try gpa.dupe(u8, msg.payload[0..newline_idx]),
                            .cwd = if (newline_idx + 1 < msg.payload.len) try gpa.dupe(u8, msg.payload[newline_idx + 1 ..]) else null,
                        };
                    },
                    else => {},
                }
            }
        }

        // Handle socket write (flush buffered messages to daemon)
        if (poll_fds.items[1].revents & lib_posix.POLL.OUT != 0) {
            if (sock_write_buf.items.len > 0) {
                const n = lib_posix.write(client_sock_fd, sock_write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                        std.log.info("connection reset or broken pipe", .{});
                        finishSession(gpa, client_sock_fd, stdout_fd, &read_buf, &stdout_buf);
                        return ClientResult{ .kind = .detach, .session_name = null };
                    }
                    return err;
                };
                if (n > 0) {
                    try sock_write_buf.replaceRange(gpa, 0, n, &[_]u8{});
                }
            }
        }

        if (stdout_buf.items.len > 0) {
            const n = lib_posix.write(stdout_fd, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (n > 0) {
                try stdout_buf.replaceRange(gpa, 0, n, &[_]u8{});
            }
        }
    }
}

/// What a client that lost its daemon may still spend on the session's last output.
const DRAIN_BUDGET_MS: i64 = 2000;
const DRAIN_MAX_BYTES: usize = 1 << 20;

/// Reads what the daemon queued before it went away and writes it, with what is already buffered, to the
/// terminal. One loop, bounded by an absolute monotonic deadline read on every pass and by DRAIN_MAX_BYTES
/// from the socket. stdout is nonblocking here, so a terminal that stopped reading cannot hold the client;
/// any write error ends it. The socket is done at EOF, at the byte cap, or when a read finds nothing.
fn finishSession(
    gpa: std.mem.Allocator,
    sock: i32,
    fd: i32,
    read_buf: *ipc.SocketBuffer,
    out: *std.ArrayList(u8),
) void {
    const deadline = nowMs() + DRAIN_BUDGET_MS;
    const flags = lib_posix.fcntl(fd, lib_posix.F.GETFL, 0) catch return;
    _ = lib_posix.fcntl(fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK) catch return;
    defer _ = lib_posix.fcntl(fd, lib_posix.F.SETFL, flags) catch {};
    var drained: usize = 0;
    var socket_done = false;
    while (nowMs() < deadline) {
        var progress = false;
        if (!socket_done) {
            if (read_buf.read(sock)) |n| {
                if (n == 0) {
                    socket_done = true;
                } else {
                    progress = true;
                    drained += n;
                    if (drained >= DRAIN_MAX_BYTES) socket_done = true;
                    while (read_buf.next()) |msg| {
                        if (msg.header.tag != .Output) continue;
                        out.appendSlice(gpa, msg.payload) catch return;
                    }
                }
            } else |_| {
                socket_done = true;
            }
        }
        if (out.items.len > 0) {
            if (lib_posix.write(fd, out.items)) |n| {
                if (n > 0) {
                    out.replaceRange(gpa, 0, n, &[_]u8{}) catch return;
                    progress = true;
                }
            } else |err| {
                if (err != error.WouldBlock) return;
            }
        } else if (socket_done) {
            return;
        }
        if (!progress) sleepMs(1);
    }
}

/// Writes `bytes` to stdout, nonblocking, for at most `budget_ms`; for the terminal reset an exiting
/// client sends, which must not hold it on a terminal that stopped reading.
pub fn writeBounded(bytes: []const u8, budget_ms: i64) void {
    const fd = lib_posix.STDOUT_FILENO;
    const flags = lib_posix.fcntl(fd, lib_posix.F.GETFL, 0) catch return;
    _ = lib_posix.fcntl(fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK) catch return;
    defer _ = lib_posix.fcntl(fd, lib_posix.F.SETFL, flags) catch {};
    const deadline = nowMs() + budget_ms;
    var rest = bytes;
    while (rest.len > 0 and nowMs() < deadline) {
        if (lib_posix.write(fd, rest)) |n| {
            rest = rest[n..];
        } else |err| {
            if (err != error.WouldBlock) return;
            sleepMs(1);
        }
    }
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    const ts = std.c.timespec{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
}

fn initTerminal(gpa: std.mem.Allocator, io: std.Io, size: ipc.Resize, cfg: *const Cfg) !ghostty_vt.Terminal {
    return ghostty_vt.Terminal.init(io, gpa, .{
        .cols = size.cols,
        .rows = size.rows,
        .max_scrollback_lines = cfg.max_scrollback_lines,
        .max_scrollback_bytes = null, // Let the line limit control scrollback.
    });
}

/// How long a daemon whose shell exited may spend delivering the output its clients have not been sent
/// yet, one deadline shared by all of them. A kill or SIGTERM ends it at once.
const EXIT_DRAIN_MS: i64 = 2000;

/// Tests set their own drain deadline, so a starved runner cannot miss one a test does not measure.
var test_exit_drain_ms: i64 = EXIT_DRAIN_MS;

fn exitDrainMs() i64 {
    return if (builtin.is_test) test_exit_drain_ms else EXIT_DRAIN_MS;
}

/// dameonLoop is what the daemon runs to send and receive ipc commands from its corresponding
/// clients.  It uses poll() as its non-blocking mechanism.
fn daemonLoop(daemon: *Daemon, gpa: std.mem.Allocator, io: std.Io, server_sock_fd: lib_posix.socket_t, pty_fd: i32) !void {
    std.log.info("daemon started session={s} pty_fd={d}", .{ daemon.session_name, pty_fd });

    try signal.openSignalPipe();
    signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(gpa, 8);
    defer poll_fds.deinit(gpa);

    const init_size = ipc.getTerminalSize(pty_fd);
    var term = try initTerminal(gpa, io, init_size, daemon.cfg);
    defer term.deinit(gpa);
    var vt_stream = term.vtStream();
    defer vt_stream.deinit();

    // Carries the tail of the previous PTY read so the task-exit marker
    // search below can see across a read() boundary. Sized to comfortably
    // hold "ZMX_TASK_COMPLETED:" (19 bytes) plus a u8 exit code and CRLF.
    var marker_carry: [32]u8 = undefined;
    var marker_carry_len: usize = 0;

    var had_terminal_client = daemon.hasTerminalClient();

    // set when the shell exits: the loop then only delivers what clients have not been sent, until none
    // is left or the deadline passes, and still serves a detach, a kill or Info
    var drain_deadline: ?i64 = null;

    daemon_loop: while (daemon.running) {
        if (drain_deadline) |deadline| {
            if (!daemon.hasUnsentOutput()) break :daemon_loop;
            if (nowMs() >= deadline) {
                std.log.info("exit drain deadline passed with output unsent", .{});
                break :daemon_loop;
            }
        }
        const draining = drain_deadline != null;

        // If the program asked for focus reports (DECSET 1004), send focus-out
        // when the last attached client leaves and focus-in when one returns,
        // as a terminal would when its window loses/gains focus.
        const has_terminal_client = daemon.hasTerminalClient();
        if (has_terminal_client != had_terminal_client and term.modes.get(.focus_event)) {
            daemon.queuePtyInput(gpa, if (has_terminal_client) "\x1b[I" else "\x1b[O");
        }
        had_terminal_client = has_terminal_client;

        poll_fds.clearRetainingCapacity();

        try poll_fds.append(gpa, .{
            .fd = server_sock_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        });

        var pty_events: i16 = lib_posix.POLL.IN;
        if (daemon.pty_write_buf.items.len > 0) {
            pty_events |= lib_posix.POLL.OUT;
        }
        // the PTY of an exited shell reports a hangup on every poll
        try poll_fds.append(gpa, .{
            .fd = if (draining) -1 else pty_fd,
            .events = pty_events,
            .revents = 0,
        });

        try poll_fds.append(gpa, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });

        for (daemon.clients.items) |client| {
            var events: i16 = lib_posix.POLL.IN;
            if (client.has_pending_output) {
                events |= lib_posix.POLL.OUT;
            }
            try poll_fds.append(gpa, .{
                .fd = client.socket_fd,
                .events = events,
                .revents = 0,
            });
        }

        const poll_timeout: i32 = if (drain_deadline) |deadline|
            @intCast(std.math.clamp(deadline - nowMs(), 0, exitDrainMs()))
        else
            -1;
        _ = try lib_posix.poll(poll_fds.items, poll_timeout);

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            signal.drainSignalPipe() catch {};
            std.log.info(
                "SIGTERM received, shutting down gracefully session={s}",
                .{daemon.session_name},
            );
            break :daemon_loop;
        }

        if (poll_fds.items[0].revents & (lib_posix.POLL.ERR | lib_posix.POLL.HUP | lib_posix.POLL.NVAL) != 0) {
            std.log.err("server socket error revents={d}", .{poll_fds.items[0].revents});
            break :daemon_loop;
        } else if (poll_fds.items[0].revents & lib_posix.POLL.IN != 0) {
            const client_fd = try lib_posix.accept(
                server_sock_fd,
                null,
                null,
                lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC,
            );
            const client = try gpa.create(Client);
            client.* = Client{
                .alloc = gpa,
                .socket_fd = client_fd,
                .read_buf = try ipc.SocketBuffer.init(gpa),
                .write_buf = undefined,
            };
            // 64KB initial capacity lets ~15 broadcast cycles (N_TTY_BUF_SIZE reads
            // * header) accumulate before the first ArrayList growth. The write
            // buffer is userspace-only: it drains via POLLOUT to the client socket,
            // which has no corresponding kernel-imposed per-write limit.
            client.write_buf = try std.ArrayList(u8).initCapacity(client.alloc, 65536);
            try daemon.clients.append(gpa, client);
            std.log.info(
                "client connected fd={d} total={d}",
                .{ client_fd, daemon.clients.items.len },
            );
        }

        const inp_flags = lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL;
        if (poll_fds.items[1].revents & inp_flags != 0) {
            // Read from PTY. Buffer is sized to N_TTY_BUF_SIZE (4096): the hard
            // kernel limit for the N_TTY line discipline. A larger buffer doesn't
            // help: each read() from a PTY master returns at most 4096 bytes
            // regardless of the userspace buffer size.
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = lib_posix.read(pty_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                break :blk 0;
            };

            if (n_opt) |n| {
                if (n == 0) {
                    // EOF: Shell exited
                    std.log.info("shell exited pty_fd={d}", .{pty_fd});
                    // what clients have not been sent yet is delivered, bounded, before shutdown frees it
                    drain_deadline = nowMs() + exitDrainMs();
                } else {
                    // Feed PTY output to terminal emulator for state tracking
                    vt_stream.nextSlice(buf[0..n]);
                    daemon.setPwd(&term);
                    daemon.has_pty_output = true;

                    // When no real terminal client has attached yet, respond to
                    // terminal queries (e.g. DA1/DA2) on behalf of the terminal.
                    // This prevents fish from waiting 10s for unanswered queries.
                    // Only clients that sent .Init (a real zmx attach) count,
                    // not a `zmx run` tail-only client.
                    if (!daemon.hasTerminalClient() and
                        daemon.pty_write_buf.items.len < Daemon.PTY_WRITE_BUF_MAX)
                    {
                        util.respondToDeviceAttributes(gpa, &daemon.pty_write_buf, buf[0..n]);
                    }

                    // In run mode, scan output for exit code marker. The marker
                    // can straddle two PTY reads (more likely under a throttled
                    // scheduler, e.g. containers), so prepend the tail carried
                    // over from the previous read before searching.
                    if (daemon.is_task_mode and daemon.task_exit_code == null) {
                        var scan_buf: [marker_carry.len + buf.len]u8 = undefined;
                        @memcpy(scan_buf[0..marker_carry_len], marker_carry[0..marker_carry_len]);
                        @memcpy(scan_buf[marker_carry_len..][0..n], buf[0..n]);
                        const scan_len = marker_carry_len + n;

                        if (try util.findTaskExitMarker(scan_buf[0..scan_len], daemon.task_id)) |exit_code| {
                            daemon.task_exit_code = exit_code;
                            daemon.task_ended_at = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());

                            std.log.info("task completed exit_code={d}", .{exit_code});

                            // Notify connected clients
                            for (daemon.clients.items) |c| {
                                ipc.appendMessage(gpa, &c.write_buf, .TaskComplete, &[_]u8{exit_code}) catch {};
                                c.has_pending_output = true;
                            }
                        }

                        marker_carry_len = @min(marker_carry.len, scan_len);
                        @memcpy(
                            marker_carry[0..marker_carry_len],
                            scan_buf[scan_len - marker_carry_len .. scan_len],
                        );
                    }

                    // Broadcast data to all clients.
                    // Rewrite OSC 133;A to include redraw=0 so the outer terminal
                    // does not clear prompt lines on resize (issue #111).
                    const broadcast_data = util.rewritePromptRedraw(gpa, buf[0..n]) orelse buf[0..n];
                    defer if (broadcast_data.ptr != buf[0..n].ptr) gpa.free(broadcast_data);
                    for (daemon.clients.items) |client| {
                        ipc.appendMessage(gpa, &client.write_buf, .Output, broadcast_data) catch |err| {
                            std.log.warn(
                                "failed to buffer output for client err={s}",
                                .{@errorName(err)},
                            );
                            continue;
                        };
                        client.has_pending_output = true;
                    }
                }
            }
        }

        if (poll_fds.items[1].revents & lib_posix.POLL.OUT != 0) {
            while (daemon.pty_write_buf.items.len > 0) {
                const n = lib_posix.write(pty_fd, daemon.pty_write_buf.items) catch |err| {
                    if (err != error.WouldBlock) {
                        std.log.warn("pty write failed: {s}", .{@errorName(err)});
                        daemon.pty_write_buf.clearRetainingCapacity();
                    }
                    break;
                };
                if (n == 0) break;
                daemon.pty_write_buf.replaceRange(gpa, 0, n, &[_]u8{}) catch unreachable;
            }
        }

        var i: usize = daemon.clients.items.len;
        // Only iterate over clients that were present when poll_fds was constructed
        // poll_fds contains [server, pty, sig_pipe, client0, client1, ...]
        // So number of clients in poll_fds is poll_fds.items.len - 3
        const num_polled_clients = poll_fds.items.len - 3;
        if (i > num_polled_clients) {
            // If we have more clients than polled (i.e. we just accepted one), start from the
            // polled ones
            i = num_polled_clients;
        }

        clients_loop: while (i > 0) {
            i -= 1;
            const client = daemon.clients.items[i];
            const revents = poll_fds.items[i + 3].revents;

            if (revents & lib_posix.POLL.IN != 0) {
                const n = client.read_buf.read(client.socket_fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    std.log.debug(
                        "client read err={s} fd={d}",
                        .{ @errorName(err), client.socket_fd },
                    );
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n == 0) {
                    // Client closed connection
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                }

                while (client.read_buf.next()) |msg| {
                    // the shell is gone: no new attach, input or command, only a detach, a kill or Info
                    if (draining) switch (msg.header.tag) {
                        .Detach, .DetachAll, .Kill, .Info => {},
                        else => continue,
                    };
                    switch (msg.header.tag) {
                        .Input => try daemon.handleInput(gpa, client, msg.payload),
                        .Send => daemon.handleSend(gpa, msg.payload),
                        .Output => try daemon.handleOutput(gpa, msg.payload, &term, &vt_stream),
                        .Init => try daemon.handleInit(gpa, client, pty_fd, &term, msg.payload),
                        .Switch => try daemon.handleSwitch(gpa, msg.payload),
                        .Resize => try daemon.handleResize(gpa, client, pty_fd, &term, msg.payload),
                        .Detach => {
                            daemon.handleDetach(gpa, client, i);
                            break :clients_loop;
                        },
                        .DetachAll => {
                            daemon.handleDetachAll(gpa);
                            break :clients_loop;
                        },
                        .Kill => {
                            break :daemon_loop;
                        },
                        .Info => try daemon.handleInfo(gpa, client, &term),
                        .LabelGet => try daemon.handleLabelGet(gpa, client),
                        .LabelSet => try daemon.handleLabelSet(gpa, client, msg.payload),
                        .LabelClear => try daemon.handleLabelClear(gpa, client),
                        .EnvGet => try daemon.handleEnvGet(gpa, client),
                        .EnvSet => try daemon.handleEnvSet(gpa, client, msg.payload),
                        .History => try daemon.handleHistory(gpa, client, &term, msg.payload),
                        .Capture => try daemon.handleCapture(gpa, client, &term, msg.payload),
                        .Run => try daemon.handleRun(gpa, io, client, msg.payload),
                        .Ack, .TaskComplete, .LabelData, .EnvData, .Unsupported => {},
                        .Write => try daemon.handleWrite(gpa, client, msg.payload),
                        _ => {
                            std.log.warn(
                                "ignoring unknown IPC tag={d}",
                                .{@backingInt(msg.header.tag)},
                            );
                            ipc.appendMessage(gpa, &client.write_buf, .Unsupported, "") catch {};
                            client.has_pending_output = true;
                        },
                    }
                }
            }

            if (revents & lib_posix.POLL.OUT != 0) {
                // Flush pending output buffers
                const n = lib_posix.write(client.socket_fd, client.write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    // Error on write, close client
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n > 0) {
                    client.write_buf.replaceRange(gpa, 0, n, &[_]u8{}) catch unreachable;
                }

                if (client.write_buf.items.len == 0) {
                    client.has_pending_output = false;
                }
            }

            if (revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
                // A client that writes and exits (`zmx send`, `zmx run -d`) is
                // reported HUP with part of its message still unread: a pass
                // reads at most 4 KiB. Closing now drops the rest. Leave it to
                // the next pass, which reads on until EOF closes the client.
                if (revents & lib_posix.POLL.IN != 0 and
                    revents & (lib_posix.POLL.ERR | lib_posix.POLL.NVAL) == 0) continue;
                const last = daemon.closeClient(gpa, client, i, false);
                if (last) break :daemon_loop;
            }
        }
    }
}

const ClientResult = struct {
    kind: enum {
        detach,
        switch_session,
    },
    session_name: ?[]const u8,
    cwd: ?[]const u8 = null,
};

/// Client represents each terminal that has connected to a session.
///
/// Multiple Clients can connect to a single session.
pub const Client = struct {
    alloc: std.mem.Allocator,
    socket_fd: i32,
    has_pending_output: bool = false,
    is_terminal: bool = false, // sent .Init (a `zmx attach`), not a run/send/tail client
    read_buf: ipc.SocketBuffer,
    write_buf: std.ArrayList(u8),
    env_str: ?[]u8 = null,

    pub fn deinit(self: *Client, gpa: std.mem.Allocator) void {
        lib_posix.close(self.socket_fd);
        self.read_buf.deinit();
        self.write_buf.deinit(self.alloc);
        if (self.env_str) |s| gpa.free(s);
    }

    fn setEnv(self: *Client, gpa: std.mem.Allocator, env_str: []const u8) !void {
        if (self.env_str) |s| gpa.free(s);
        self.env_str = if (env_str.len > 0) try gpa.dupe(u8, env_str) else null;
    }
};

/// Daemon is responsible for managing a zmx session.
///
/// It holds all the state for a running session.  Instead of a single daemon for all sessions, we
/// create a daemon for every session.  This has some benefits. The ipc communication between
/// session clients and the daemon doesn't need to be tagged with the session name.  If a daemon
/// crashes for one session won't crash all the other sessions.
///
/// Conceptually it's also much simpler to reason about.
pub const Daemon = struct {
    cfg: *Cfg,
    session_name: []const u8,
    socket_path: []const u8,
    // === opt ===
    pty_write_buf: std.ArrayList(u8) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    labels: std.StringHashMapUnmanaged([]u8) = .empty,
    // This control which client is the leader.  The leader controls terminal state and
    // cols/rows of session.
    leader_client_fd: ?i32 = null,
    running: bool = true,
    pid: i32 = undefined,
    command: ?[]const []const u8 = null,
    /// The session's working directory in OSC 7 form, `file://<host><path>`.
    /// Kept as a URI rather than a path so `zmx list` shows the host, which is
    /// what tells you a session is inside SSH. Points into `cwd_buf` once set,
    /// so a Daemon must not be copied by value after that.
    cwd: []const u8 = "",
    /// The same directory as a path that can be opened: percent-decoding
    /// applied, scheme and host stripped. Empty when the cwd is on another
    /// host, since then it names no directory here and nothing should chdir
    /// into it. Points into `cwd_path_buf`.
    cwd_path: []const u8 = "",
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    has_pty_output: bool = false,
    created_at: u64, // unix timestamp (ns)
    is_task_mode: bool = false, // flag for when session is run as a task
    task_id: [4]u8 = undefined,
    task_exit_code: ?u8 = null, // null = running or n/a, set when task completes
    task_ended_at: ?u64 = null, // timestamp when task exited
    pty_fd: i32 = -1, // set by daemonLoop so handleRun can probe the foreground process
    shell: []const u8 = "/bin/sh",
    quiet: bool = false,

    /// Create a Daemon. Caller is responsible for freeing all variables passed
    /// into the init fn.
    pub fn init(io: std.Io, cfg: *Cfg, sesh_name: []const u8, socket_path: []const u8) Daemon {
        return .{
            .cfg = cfg,
            .session_name = sesh_name,
            .socket_path = socket_path,
            .created_at = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        };
    }

    pub fn deinit(self: *Daemon, gpa: std.mem.Allocator) void {
        self.clients.deinit(gpa);
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.labels.deinit(gpa);
        self.pty_write_buf.deinit(gpa);
    }

    pub fn shutdown(self: *Daemon, gpa: std.mem.Allocator) void {
        std.log.info("shutting down daemon session={s}", .{self.session_name});
        self.running = false;

        for (self.clients.items) |client| {
            client.deinit(gpa);
            gpa.destroy(client);
        }
        self.clients.clearRetainingCapacity();
    }

    /// Resize the daemon's terminal with prompt_redraw disabled. On resize the
    /// terminal would clear prompt lines expecting the shell to redraw them,
    /// but the shell's redraw goes to the PTY (forwarded to clients), not to
    /// this terminal, so the clearing only corrupts our snapshot state.
    fn resizeTerm(gpa: std.mem.Allocator, term: *ghostty_vt.Terminal, cols: u16, rows: u16) !void {
        const saved = term.flags.shell_redraws_prompt;
        term.flags.shell_redraws_prompt = .false;
        defer term.flags.shell_redraws_prompt = saved;
        try term.resize(gpa, .{ .cols = cols, .rows = rows });
    }

    /// True while a client that sent .Init (a real `zmx attach`) is connected.
    fn hasTerminalClient(self: *const Daemon) bool {
        for (self.clients.items) |c| {
            if (c.is_terminal) return true;
        }
        return false;
    }

    /// True while any client has output queued that it has not been sent.
    fn hasUnsentOutput(self: *const Daemon) bool {
        for (self.clients.items) |c| {
            if (c.write_buf.items.len > 0) return true;
        }
        return false;
    }

    pub fn closeClient(self: *Daemon, gpa: std.mem.Allocator, client: *Client, i: usize, shutdown_on_last: bool) bool {
        const fd = client.socket_fd;
        // leader is disconnected, remove ref and let another client claim leader on input
        if (self.leader_client_fd == client.socket_fd) {
            std.log.info(
                "unsetting leader session={s} fd={d}",
                .{ self.session_name, client.socket_fd },
            );
            self.leader_client_fd = null;
        }
        client.deinit(gpa);
        gpa.destroy(client);
        _ = self.clients.orderedRemove(i);
        std.log.info("client disconnected fd={d} remaining={d}", .{ fd, self.clients.items.len });
        if (shutdown_on_last and self.clients.items.len == 0) {
            self.shutdown(gpa);
            return true;
        }
        return false;
    }

    /// ensureSession will either create or re-use the daemon used for a session.
    /// It will spin up a unix socket, double-fork the process (so it survives
    /// the terminal dying), and automatically attach the client to the ipc unix
    /// socket.
    ///
    /// The return bool value indicates if the current process is the daemon
    /// or the client since they have different behaviors post-fork.
    ///
    /// E.g. If it's the client process then we need to connect to the unix socket
    /// and run the clientLoop.  If it's the daemon then we need to bail since
    /// the daemonLoop is created inside this fn and when it returns that means
    /// the daemon stopped and needs to exit.
    pub fn ensureSession(self: *Daemon, io: std.Io) !bool {
        const sesh_name = self.session_name;
        std.log.info("ensure session session={s}", .{sesh_name});
        var dir = try std.Io.Dir.openDirAbsolute(io, self.cfg.socket_dir, .{});
        defer dir.close(io);

        const exists = try socket.sessionExists(io, dir, sesh_name);
        // if daemon is gone then we flip this to true
        var should_create = !exists;

        if (exists) {
            if (ipc.connectSession(self.socket_path)) |fd| {
                lib_posix.close(fd);
                if (self.command != null) {
                    std.log.warn(
                        "session already exists, ignoring command session={s}",
                        .{sesh_name},
                    );
                }
            } else |err| switch (err) {
                // Daemon is definitively gone: safe to replace.
                error.ConnectionRefused => {
                    socket.cleanupStaleSocket(io, dir, sesh_name);
                    should_create = true;
                },
                // Connect failed for an unusual reason. The check is only to
                // decide create-vs-attach; the socket file exists, so proceed
                // to attach rather than fail or orphan.
                else => {
                    std.log.warn(
                        "connect failed ({s}), proceeding to attach session={s}",
                        .{ @errorName(err), sesh_name },
                    );
                },
            }
        }

        if (!should_create) {
            return false;
        }

        return self.run(io, dir, sesh_name);
    }

    fn run(self: *Daemon, io: std.Io, dir: std.Io.Dir, sesh_name: []const u8) !bool {
        std.log.info("creating session={s}", .{sesh_name});
        const server_sock_fd: lib_posix.socket_t = try socket.createSocket(self.socket_path);
        const log_fd = if (log.log_system.file) |f| f.handle else -1;

        var keep_fds_open = [_]i32{ server_sock_fd, dir.handle, log_fd };
        const cmd = try daemonize.createCmdZ(self.shell, self.is_task_mode, self.command);

        // `cwd_path` is the decoded path, and is empty when the cwd is on
        // another host: OSC 7 crosses SSH boundaries, so a session that ssh'd
        // elsewhere reports a directory that does not exist on this machine.
        std.log.info("checking pwd={s} path={s}", .{ self.cwd, self.cwd_path });
        if (self.cwd_path.len > 0) {
            const pwd_dir = std.Io.Dir.openDirAbsolute(io, self.cwd_path, .{}) catch |err| blk: {
                std.log.warn("failed to open dir={s} err={s}", .{ self.cwd_path, @errorName(err) });
                break :blk null;
            };
            if (pwd_dir) |pdir| {
                defer std.Io.Dir.close(pdir, io);
                std.log.info("set directory dir={s}", .{self.cwd_path});
                try std.process.setCurrentDir(io, pdir);
            }
        }

        const pty_info = daemonize.daemonize(
            sesh_name,
            cmd,
            &keep_fds_open,
        ) catch |err| {
            switch (err) {
                error.IsClientProc => {
                    // send a msg to the client that the session was created.
                    if (!self.quiet) {
                        var w_buf: [2048]u8 = undefined;
                        var w = std.Io.File.stdout().writer(io, &w_buf);
                        try w.interface.print("session \"{s}\" created\n", .{sesh_name});
                        try w.interface.flush();
                    }
                    lib_posix.close(server_sock_fd);
                    return false;
                },
                else => {
                    lib_posix.close(server_sock_fd);
                    dir.deleteFile(io, self.session_name) catch {};
                    return err;
                },
            }
        };
        // =======
        // WARNING: cannot use upstream allocator or io after this point since
        // we forked the process and there's a risk of a mutex (e.g. thread-safe
        // allocator) being locked by a thread prior to fork which can cause a
        // deadlock.
        // =======

        self.pid = pty_info.pid;

        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const new_io = threaded.io();

        { // re-initialize logs with the session name as the filename
            log.log_system.deinit();
            var log_buf: [4096]u8 = undefined;
            const session_log_name = try std.fmt.bufPrint(
                &log_buf,
                "{s}.log",
                .{sesh_name},
            );
            var fba_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const session_log_path = try std.fs.path.join(
                fba.allocator(),
                &.{ self.cfg.log_dir, session_log_name },
            );
            const log_mode = std.Io.File.Permissions.fromMode(@intCast(self.cfg.log_mode));
            log.log_system.init(new_io, session_log_path, log_mode) catch {};
        }

        const gpa: std.mem.Allocator = blk: {
            if (builtin.mode == .debug) {
                const GPA = std.heap.DebugAllocator(.{});
                const Static = struct {
                    var gpa: GPA = .{};
                };
                break :blk Static.gpa.allocator();
            }
            break :blk std.heap.c_allocator;
        };

        defer {
            // Close and unlink the listen socket BEFORE handleKill()'s
            // 500ms SIGHUP->SIGKILL grace sleep. Otherwise a `zmx run`
            // for the same name issued in that window will hang waiting
            // for a connect.
            lib_posix.close(server_sock_fd);
            std.log.info("deleting socket file session={s}", .{sesh_name});
            dir.deleteFile(new_io, sesh_name) catch |err| {
                std.log.warn("failed to delete socket file err={s}", .{@errorName(err)});
            };
            self.handleKill(gpa, new_io);
            self.deinit(gpa);
            lib_posix.close(pty_info.master_fd);
            _ = lib_posix.waitpid(self.pid, 0);
        }

        try daemonLoop(self, gpa, new_io, server_sock_fd, pty_info.master_fd);
        std.log.info("daemon loop shutdown", .{});
        return true;
    }

    fn setLeader(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        std.log.info("setting new leader client_fd={d}", .{client.socket_fd});
        self.leader_client_fd = client.socket_fd;
        // Send a resize message to the client so it can send us back their window size
        // so we can resize the pty and ghostty state.
        try ipc.appendMessage(gpa, &client.write_buf, .Resize, "");
        client.has_pending_output = true;
    }

    fn getLeaderClient(self: *Daemon) ?*Client {
        for (self.clients.items) |client| {
            if (self.leader_client_fd == client.socket_fd) {
                return client;
            }
        }
        return null;
    }

    const PTY_WRITE_BUF_MAX = 256 * 1024;

    /// Queue bytes for the PTY's stdin. Flushed by daemonLoop on POLLOUT.
    /// Drops the payload if the buffer is over cap -- same failure mode as
    /// the old direct-write ptyWrite (drop on EAGAIN), just at a 64x higher
    /// threshold. Capping avoids OOM when the shell stops reading; dropping
    /// new (not old) bytes avoids tearing a partially-accepted sequence.
    fn queuePtyInput(self: *Daemon, gpa: std.mem.Allocator, data: []const u8) void {
        if (data.len == 0) return;
        if (self.pty_write_buf.items.len + data.len > PTY_WRITE_BUF_MAX) {
            std.log.warn(
                "pty input dropped {d} bytes (buffer full, shell not reading)",
                .{data.len},
            );
            return;
        }

        // NOTE: for local dev only
        // std.log.debug("buffering pty input data={x}", .{data});

        self.pty_write_buf.appendSlice(gpa, data) catch |err| {
            std.log.warn(
                "pty input dropped {d} bytes: {s}",
                .{ data.len, @errorName(err) },
            );
        };
    }

    pub fn handleInput(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        // NOTE: for local dev only
        // std.log.debug("buffering pty input data={x}", .{payload});

        // client is leader, send entire payload (ansi escape codes + text)
        if (self.leader_client_fd == client.socket_fd) {
            self.queuePtyInput(gpa, payload);
            return;
        }

        // check if leader needs to be updated by detecting any user input
        if (util.isUserInput(payload)) {
            try self.setLeader(gpa, client);
            self.queuePtyInput(gpa, payload);
        }
    }

    /// Queue input from `zmx send` without changing interactive client leadership.
    pub fn handleSend(self: *Daemon, gpa: std.mem.Allocator, payload: []const u8) void {
        self.queuePtyInput(gpa, payload);
    }

    pub fn handleSwitch(self: *Daemon, gpa: std.mem.Allocator, session_name: []const u8) !void {
        for (self.clients.items) |client| {
            if (self.leader_client_fd == client.socket_fd) {
                // Include the daemon's current cwd so the new session can start
                // in the right directory. A remote cwd is left out: it names no
                // directory here, so the new session is better off with the
                // attaching client's own cwd than with a path it cannot enter.
                if (self.cwd.len > 0 and self.cwd_path.len > 0) {
                    var payload = gpa.alloc(u8, session_name.len + 1 + self.cwd.len) catch return;
                    defer gpa.free(payload);
                    @memcpy(payload[0..session_name.len], session_name);
                    payload[session_name.len] = '\n';
                    @memcpy(payload[session_name.len + 1 ..], self.cwd);
                    ipc.appendMessage(gpa, &client.write_buf, .Switch, payload) catch |err| {
                        std.log.warn(
                            "failed to buffer terminal state for client err={s}",
                            .{@errorName(err)},
                        );
                    };
                } else {
                    ipc.appendMessage(gpa, &client.write_buf, .Switch, session_name) catch |err| {
                        std.log.warn(
                            "failed to buffer terminal state for client err={s}",
                            .{@errorName(err)},
                        );
                    };
                }
                client.has_pending_output = true;
                return;
            }
        }
    }

    pub fn handleInit(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;

        if (!client.is_terminal) {
            client.write_buf.clearRetainingCapacity();
            client.has_pending_output = false;
        }
        client.is_terminal = true;

        if (self.leader_client_fd == null) {
            try self.setLeader(gpa, client);
        }
        const is_leader = self.leader_client_fd == client.socket_fd;
        const resize = std.mem.bytesToValue(ipc.Resize, payload);

        // Resize our terminal (not yet the PTY) to the leader's size before
        // serializing, so the snapshot is laid out for the width the client
        // will render it at instead of being wrapped a second time on arrival.
        // Cursor position stays consistent because it is serialized from the
        // same, already-resized terminal; the PTY is resized below, so the
        // shell's own SIGWINCH redraw still arrives after the snapshot.
        if (is_leader) {
            try resizeTerm(gpa, term, resize.cols, resize.rows);
        }

        if (self.has_pty_output) {
            const cursor = &term.screens.active.cursor;
            std.log.debug(
                "cursor before serialize: x={d} y={d} pending_wrap={}",
                .{ cursor.x, cursor.y, cursor.pending_wrap },
            );
            if (util.serializeTerminalState(gpa, term)) |term_output| {
                std.log.debug("serialize terminal state", .{});
                // Rewrite OSC 133;A to include redraw=0 so the outer terminal
                // does not clear prompt lines on resize (issue #111).
                const restore_data = util.rewritePromptRedraw(gpa, term_output) orelse term_output;
                defer gpa.free(term_output);
                defer if (restore_data.ptr != term_output.ptr) gpa.free(restore_data);
                ipc.appendMessage(gpa, &client.write_buf, .Output, restore_data) catch |err| {
                    std.log.warn(
                        "failed to buffer terminal state for client err={s}",
                        .{@errorName(err)},
                    );
                };
                client.has_pending_output = true;
            }
        }

        // only resize if leader
        if (is_leader) {
            var ws = resize.winsize();
            _ = cross.ioctl(pty_fd, cross.TIOCSWINSZ, &ws);

            // On re-attach, deliver SIGWINCH to the foreground process group so
            // incremental renderers (Ink, Claude Code, etc.) know to repaint.
            // If the size changed, TIOCSWINSZ above already sent SIGWINCH; if the size
            // was unchanged, the kernel suppressed it, so signal the pgrp explicitly.
            if (self.has_pty_output) {
                var pgrp: lib_posix.pid_t = 0;
                if (cross.ioctl(pty_fd, cross.TIOCGPGRP, &pgrp) == 0 and pgrp > 0) {
                    lib_posix.kill(-pgrp, .WINCH) catch {};
                }
            }

            std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });
        }
    }

    pub fn handleResize(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;
        if (self.leader_client_fd == null) {
            try self.setLeader(gpa, client);
        }
        // only leader can resize
        if (self.leader_client_fd != client.socket_fd) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        var ws = resize.winsize();
        _ = cross.ioctl(pty_fd, cross.TIOCSWINSZ, &ws);
        try resizeTerm(gpa, term, resize.cols, resize.rows);
        std.log.debug("resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleDetach(self: *Daemon, gpa: std.mem.Allocator, client: *Client, i: usize) void {
        std.log.info("client detach session={s} fd={d}", .{ self.session_name, client.socket_fd });
        _ = self.closeClient(gpa, client, i, false);
    }

    pub fn handleDetachAll(self: *Daemon, gpa: std.mem.Allocator) void {
        std.log.info("detach all clients={d}", .{self.clients.items.len});
        // Go through closeClient so the leader is cleared like any other detach.
        while (self.clients.items.len > 0) {
            const last = self.clients.items.len - 1;
            _ = self.closeClient(gpa, self.clients.items[last], last, false);
        }
    }

    pub fn handleKill(self: *Daemon, gpa: std.mem.Allocator, io: std.Io) void {
        std.log.info("kill received session={s}", .{self.session_name});
        self.shutdown(gpa);
        // gracefully shutdown shell processes, shells tend to ignore SIGTERM so we send SIGHUP
        // instead
        //   https://www.gnu.org/software/bash/manual/html_node/Signals.html
        // negative pid means kill process and children
        std.log.info("sending SIGHUP session={s} pid={d}", .{ self.session_name, self.pid });
        lib_posix.kill(-self.pid, lib_posix.SIG.HUP) catch |err| {
            std.log.warn("failed to send SIGHUP to pty child err={s}", .{@errorName(err)});
        };
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .real) catch unreachable;
        lib_posix.kill(-self.pid, lib_posix.SIG.KILL) catch |err| {
            std.log.warn("failed to send SIGKILL to pty child err={s}", .{@errorName(err)});
        };
    }

    pub fn handleInfo(self: *Daemon, gpa: std.mem.Allocator, client: *Client, term: *ghostty_vt.Terminal) !void {
        self.setPwd(term);

        // zeroes() so asBytes() doesn't ship struct padding + unused cmd/cwd
        // tail bytes (daemon stack contents) to clients.
        var info = std.mem.zeroes(ipc.Info);
        info.protocol_version = ipc.PROTOCOL_VERSION;
        info.clients_len = self.clients.items.len - 1;
        info.pid = self.pid;
        info.created_at = self.created_at;
        info.task_ended_at = self.task_ended_at orelse 0;
        info.task_exit_code = self.task_exit_code orelse 0;

        // Build command string from args, re-quoting args that contain
        // shell-special characters so the displayed command is copy-pasteable.
        const cur_cmd = self.command;
        if (cur_cmd) |args| {
            for (args, 0..) |arg, i| {
                const quoted = if (util.shellNeedsQuoting(arg))
                    util.shellQuote(gpa, arg) catch null
                else
                    null;
                defer if (quoted) |q| gpa.free(q);
                const src = quoted orelse arg;

                const need = src.len + @as(usize, if (i > 0) 1 else 0);
                if (info.cmd_len + need > ipc.MAX_CMD_LEN) {
                    const ellipsis = "...";
                    if (info.cmd_len + ellipsis.len <= ipc.MAX_CMD_LEN) {
                        @memcpy(info.cmd[info.cmd_len..][0..ellipsis.len], ellipsis);
                        info.cmd_len += ellipsis.len;
                    }
                    break;
                }

                if (i > 0) {
                    info.cmd[info.cmd_len] = ' ';
                    info.cmd_len += 1;
                }
                @memcpy(info.cmd[info.cmd_len..][0..src.len], src);
                info.cmd_len += @intCast(src.len);
            }
        }

        info.cwd_len = @intCast(@min(self.cwd.len, ipc.MAX_CWD_LEN));
        @memcpy(info.cwd[0..info.cwd_len], self.cwd[0..info.cwd_len]);

        try ipc.appendMessage(gpa, &client.write_buf, .Info, std.mem.asBytes(&info));
        client.has_pending_output = true;
    }

    pub fn handleHistory(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        self.setPwd(term);
        const format: util.HistoryFormat = if (payload.len > 0)
            @fromBackingInt(@intCast(payload[0]))
        else
            .plain;
        if (util.serializeTerminal(gpa, term, format)) |output| {
            defer gpa.free(output);
            try ipc.appendMessage(gpa, &client.write_buf, .History, output);
            client.has_pending_output = true;
        } else {
            try ipc.appendMessage(gpa, &client.write_buf, .History, "");
            client.has_pending_output = true;
        }
    }

    pub fn handleCapture(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Capture)) return;
        const request = std.mem.bytesToValue(ipc.Capture, payload);
        const format = std.enums.fromInt(util.HistoryFormat, request.format) orelse return;
        self.setPwd(term);
        const output = util.serializeTerminalRange(gpa, term, format, request.rows);
        defer if (output) |text| gpa.free(text);
        try ipc.appendMessage(gpa, &client.write_buf, .Capture, output orelse "");
        client.has_pending_output = true;
    }

    pub fn handleRun(self: *Daemon, gpa: std.mem.Allocator, io: std.Io, client: *Client, payload: []const u8) !void {
        // Reset task tracking so the new command's exit marker is detected.
        // Without this, a second `zmx run` on the same session is ignored
        // because task_exit_code is still set from the first run.
        self.task_exit_code = null;
        self.task_ended_at = null;
        self.is_task_mode = true;
        self.task_id = util.generateTaskId(io);

        if (payload.len == 0) return;

        const cmd = payload;

        // Chain the exit marker with `;` on the same line. `$?` captures the
        // exit code of the command (not the `;`). The sole exception is when
        // the command contains a heredoc (`<<`), the delimiter must be alone
        // on its line, so the marker goes on the next line instead.
        var buf: [1024]u8 = undefined;
        const marker = try util.getTaskExitMarker(&buf, self.task_id);
        var single_buf: [1024]u8 = undefined;
        const single_line_marker = try std.fmt.bufPrint(&single_buf, "; echo {s}$?\r", .{marker});
        var here_buf: [1024]u8 = undefined;
        const heredoc_marker = try std.fmt.bufPrint(&here_buf, "\r\necho {s}$?\r", .{marker});
        const uses_heredoc = std.mem.indexOf(u8, cmd, "<<") != null;

        if (cmd.len > 0 and cmd[cmd.len - 1] == '\r') {
            self.queuePtyInput(gpa, cmd[0 .. cmd.len - 1]);
        } else {
            self.queuePtyInput(gpa, cmd);
        }
        self.queuePtyInput(gpa, if (uses_heredoc) heredoc_marker else single_line_marker);

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        std.log.debug("run command len={d}", .{payload.len});
    }

    /// Store the session's working directory as a plain path.
    ///
    /// Accepts either an OSC 7 value (`file://<host><path>`, percent-encoded)
    /// or a path. Decoding here rather than at each use keeps `zmx list`
    /// printing a path and lets the chdir on session create find directories
    /// whose names needed escaping.
    ///
    /// The value is copied, so callers may pass a temporary.
    pub fn setCwd(self: *Daemon, value: []const u8) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&host_buf) catch "";
        const cwd = util.parseOsc7Cwd(&buf, value, hostname) orelse {
            std.log.warn("ignoring unusable cwd={s}", .{value});
            return;
        };

        // Store the URI form. A caller that handed us a plain path gets one
        // built here, so `cwd` has the same shape no matter the source. A value
        // that already was a URI is kept verbatim, so `list` shows what the
        // shell actually reported.
        self.cwd = if (std.fs.path.isAbsolute(value))
            util.toOsc7Cwd(&self.cwd_buf, value, hostname) orelse return
        else blk: {
            if (value.len > self.cwd_buf.len) return;
            @memcpy(self.cwd_buf[0..value.len], value);
            break :blk self.cwd_buf[0..value.len];
        };

        // Only keep an openable path when it names a directory on this host.
        if (cwd.is_local and cwd.path.len <= self.cwd_path_buf.len) {
            @memcpy(self.cwd_path_buf[0..cwd.path.len], cwd.path);
            self.cwd_path = self.cwd_path_buf[0..cwd.path.len];
        } else {
            self.cwd_path = "";
        }
        std.log.info("set cwd={s} path={s}", .{ self.cwd, self.cwd_path });
    }

    fn setPwd(self: *Daemon, term: *ghostty_vt.Terminal) void {
        const pwd = term.getPwd() orelse return;
        if (std.mem.eql(u8, self.cwd, pwd)) return;
        self.setCwd(pwd);
    }

    pub fn handleOutput(self: *Daemon, gpa: std.mem.Allocator, payload: []const u8, term: *ghostty_vt.Terminal, vt_stream: anytype) !void {
        vt_stream.nextSlice(payload);
        self.setPwd(term);
        self.has_pty_output = true;
        for (self.clients.items) |client| {
            try ipc.appendMessage(gpa, &client.write_buf, .Output, payload);
            client.has_pending_output = true;
        }
        if (self.clients.items.len > 0) {
            lib_posix.kill(self.pid, lib_posix.SIG.WINCH) catch |err| {
                std.log.warn("failed to send SIGWINCH err={s}", .{@errorName(err)});
            };
        }
    }

    pub fn handleWrite(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        // Wire format: [u32 path len][path bytes][file content]
        if (payload.len < @sizeOf(u32)) return error.InvalidPayload;
        const path_len = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]);
        if (payload.len < @sizeOf(u32) + path_len) return error.InvalidPayload;
        const file_path = payload[@sizeOf(u32)..][0..path_len];
        const file_content = payload[@sizeOf(u32) + path_len ..];

        // Inject file creation through the PTY so it works over SSH.
        // Base64-encode content and pipe through printf | base64 -d > file.
        // Chunk large files to stay under command-line length limits.
        // 48000 is divisible by 3 (clean base64 boundaries) and encodes
        // to ~64KB, well under typical ARG_MAX.
        // The commands skip queuePtyInput's cap: it would drop the chunks
        // past PTY_WRITE_BUF_MAX and leave the file cut short. The payload
        // is already bounded by ipc.MAX_PAYLOAD_LEN.
        const chunk_size = 48000;
        var offset: usize = 0;
        var is_first = true;

        while (offset < file_content.len or is_first) {
            const end = @min(offset + chunk_size, file_content.len);
            const chunk = file_content[offset..end];

            const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
            const encoded = try gpa.alloc(u8, encoded_len);
            defer gpa.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, chunk);

            try self.pty_write_buf.appendSlice(gpa, "printf '%s' '");
            try self.pty_write_buf.appendSlice(gpa, encoded);
            if (is_first) {
                try self.pty_write_buf.appendSlice(gpa, "' | base64 -d > '");
            } else {
                try self.pty_write_buf.appendSlice(gpa, "' | base64 -d >> '");
            }
            try self.pty_write_buf.appendSlice(gpa, file_path);
            try self.pty_write_buf.appendSlice(gpa, "'");
            try self.pty_write_buf.appendSlice(gpa, "\r");

            offset = end;
            is_first = false;
        }

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        std.log.debug(
            "write command len={d} file_path={s}",
            .{ file_content.len, file_path },
        );
    }

    fn handleEnvGet(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        const leader_opt = self.getLeaderClient();
        const payload = if (leader_opt) |leader| leader.env_str orelse "" else "";
        try ipc.appendMessage(gpa, &client.write_buf, .EnvData, payload);
        client.has_pending_output = true;
    }

    fn handleEnvSet(_: *Daemon, gpa: std.mem.Allocator, client: *Client, env_str: []const u8) !void {
        std.log.info("handle env set payload={s}", .{env_str});
        try client.setEnv(gpa, env_str);

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }

    fn handleLabelGet(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        const out = try label.labelsToU8(gpa, self.labels);
        defer gpa.free(out);
        try ipc.appendMessage(gpa, &client.write_buf, .LabelData, out);
        client.has_pending_output = true;
    }

    fn handleLabelSet(self: *Daemon, gpa: std.mem.Allocator, client: *Client, labels: []const u8) !void {
        std.log.info("handle label set payload={s}", .{labels});

        var kvs = label.LabelIterator.init(labels);
        while (kvs.next()) |kv| {
            if (kv.value.len == 0) {
                if (self.labels.fetchRemove(kv.key)) |existing| {
                    gpa.free(existing.key);
                    gpa.free(existing.value);
                }
                continue;
            }

            const owned_key = try gpa.dupe(u8, kv.key);
            errdefer gpa.free(owned_key);
            const owned_value = try gpa.dupe(u8, kv.value);
            errdefer gpa.free(owned_value);
            if (try self.labels.fetchPut(gpa, owned_key, owned_value)) |existing| {
                // fetchPut does NOT replace the key in the map, the old
                // key pointer stays. So free the new (unused) key and the
                // old value.
                gpa.free(owned_key);
                gpa.free(existing.value);
            }
        }

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }

    fn handleLabelClear(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.labels.clearRetainingCapacity();
        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }
};

test "daemon deinit leaves the caller-owned socket path intact" {
    var cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var socket_path = "/tmp/zmx-test/socket".*;
    var daemon = Daemon.init(std.testing.io, &cfg, "test", &socket_path);

    daemon.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/tmp/zmx-test/socket", &socket_path);
}

test "terminal retains the configured scrollback without the default byte cap" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("first line\r\n");
    for (1..cfg.max_scrollback_lines) |_| stream.nextSlice("more output\r\n");

    const history = util.serializeTerminal(alloc, &term, .plain) orelse return error.TestUnexpectedNull;
    defer alloc.free(history);
    try std.testing.expect(std.mem.startsWith(u8, history, "first line\n"));

    // Exceed the limit comfortably because Ghostty prunes whole pages.
    for (0..cfg.max_scrollback_lines) |_| stream.nextSlice("more output\r\n");
    stream.nextSlice("latest line\r\n");

    const pruned_history = util.serializeTerminal(alloc, &term, .plain) orelse return error.TestUnexpectedNull;
    defer alloc.free(pruned_history);
    try std.testing.expect(std.mem.indexOf(u8, pruned_history, "first line") == null);
    try std.testing.expect(std.mem.indexOf(u8, pruned_history, "latest line") != null);
}

fn testDaemon() Daemon {
    return .{
        .cfg = undefined,
        .clients = .empty,
        .leader_client_fd = null,
        .session_name = "test",
        .socket_path = "",
        .running = true,
        .pid = 0,
        .created_at = 0,
    };
}

fn testClient(alloc: std.mem.Allocator, fd: i32, is_terminal: bool) !*Client {
    const c = try alloc.create(Client);
    c.* = .{ .alloc = alloc, .socket_fd = fd, .read_buf = try ipc.SocketBuffer.init(alloc), .write_buf = .empty };
    c.is_terminal = is_terminal;
    return c;
}

test "hasTerminalClient follows attach, detach and detach-all" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);

    // Real fds (pipes) so Client.deinit's close() is legal.
    const a = try lib_posix.pipe2(.{});
    const b = try lib_posix.pipe2(.{});

    try std.testing.expect(!daemon.hasTerminalClient());

    // A run/send/tail client doesn't count.
    const tail_client = try testClient(alloc, a[0], false);
    try daemon.clients.append(alloc, tail_client);
    try std.testing.expect(!daemon.hasTerminalClient());

    // An attach client does, until it disconnects.
    const term_client = try testClient(alloc, a[1], true);
    try daemon.clients.append(alloc, term_client);
    try std.testing.expect(daemon.hasTerminalClient());
    _ = daemon.closeClient(alloc, tail_client, 0, false);
    try std.testing.expect(daemon.hasTerminalClient());
    _ = daemon.closeClient(alloc, term_client, 0, false);
    try std.testing.expect(!daemon.hasTerminalClient());

    try daemon.clients.append(alloc, try testClient(alloc, b[0], true));
    try daemon.clients.append(alloc, try testClient(alloc, b[1], true));
    daemon.handleDetachAll(alloc);
    try std.testing.expect(!daemon.hasTerminalClient());
    try std.testing.expectEqual(@as(?i32, null), daemon.leader_client_fd);
}

test "send queues PTY input without changing leader" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    daemon.leader_client_fd = 42;
    defer daemon.pty_write_buf.deinit(alloc);

    daemon.handleSend(alloc, "hello");

    try std.testing.expectEqual(@as(?i32, 42), daemon.leader_client_fd);
    try std.testing.expectEqualStrings("hello", daemon.pty_write_buf.items);
}

test "handleEnvGet returns leader client's environment variables including unsets" {
    const alloc = std.testing.allocator;
    var cfg = Cfg{
        .socket_dir = "/tmp",
        .log_dir = "/tmp",
    };

    var daemon = Daemon{
        .cfg = &cfg,
        .clients = .empty,
        .session_name = "test",
        .socket_path = try alloc.dupe(u8, ""),
        .running = true,
        .pid = 0,
        .created_at = 0,
    };
    defer daemon.deinit(alloc);

    const fds1 = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds1[1]);
    var client1 = Client{
        .alloc = alloc,
        .socket_fd = fds1[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client1.deinit(alloc);
    try client1.setEnv(alloc, "DISPLAY=:1\nSSH_AUTH_SOCK=/tmp/ssh-1\nKITTY_LISTEN_ON=unix:/tmp/kitty-1\n-WINDOWID\n");

    const fds2 = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds2[1]);
    var client2 = Client{
        .alloc = alloc,
        .socket_fd = fds2[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client2.deinit(alloc);
    try client2.setEnv(alloc, "SSH_AUTH_SOCK=/tmp/ssh-2\nWINDOWID=12345\nKITTY_LISTEN_ON=unix:/tmp/kitty-2\n-DISPLAY\n");

    const fds_req = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds_req[1]);
    var client_req = Client{
        .alloc = alloc,
        .socket_fd = fds_req[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client_req.deinit(alloc);

    try daemon.clients.append(alloc, &client1);
    try daemon.clients.append(alloc, &client2);

    // No leader yet -> handleEnvGet returns empty string payload
    try daemon.handleEnvGet(alloc, &client_req);
    try std.testing.expect(client_req.write_buf.items.len > 0);
    client_req.write_buf.clearRetainingCapacity();

    // Set client1 as leader
    try daemon.setLeader(alloc, &client1);
    try std.testing.expectEqual(@as(?i32, fds1[0]), daemon.leader_client_fd);
    try daemon.handleEnvGet(alloc, &client_req);
    // Wire message: [Header][Payload]
    const pay1 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("DISPLAY=:1\nSSH_AUTH_SOCK=/tmp/ssh-1\nKITTY_LISTEN_ON=unix:/tmp/kitty-1\n-WINDOWID\n", pay1);
    client_req.write_buf.clearRetainingCapacity();

    // Switch leader to client2
    try daemon.setLeader(alloc, &client2);
    try std.testing.expectEqual(@as(?i32, fds2[0]), daemon.leader_client_fd);
    try daemon.handleEnvGet(alloc, &client_req);
    const pay2 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("SSH_AUTH_SOCK=/tmp/ssh-2\nWINDOWID=12345\nKITTY_LISTEN_ON=unix:/tmp/kitty-2\n-DISPLAY\n", pay2);
    client_req.write_buf.clearRetainingCapacity();

    // Client2 updates env
    try daemon.handleEnvSet(alloc, &client2, "DISPLAY=:99\n");
    try daemon.handleEnvGet(alloc, &client_req);
    const pay3 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("DISPLAY=:99\n", pay3);
}

/// The handlers and self-pipe a client loop installs, restored when a test's client returns.
const SavedClientSignals = struct {
    const signals = [_]lib_posix.SIG{ lib_posix.SIG.WINCH, lib_posix.SIG.TERM, lib_posix.SIG.HUP, lib_posix.SIG.INT };
    pipe: [2]lib_posix.fd_t,
    actions: [signals.len]lib_posix.Sigaction = undefined,

    fn save() SavedClientSignals {
        var saved: SavedClientSignals = .{ .pipe = signal.sig_pipe };
        for (signals, &saved.actions) |sig, *action| lib_posix.sigaction(sig, null, action);
        return saved;
    }

    fn restore(self: *const SavedClientSignals) void {
        for (signals, &self.actions) |sig, *action| lib_posix.sigaction(sig, action, null);
        signal.sig_pipe = self.pipe;
    }
};

extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

/// A raw PTY of the given size, so what is written to one side reaches the other byte for byte.
fn testPty(rows: u16, cols: u16) ![2]i32 {
    const master = try lib_posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer lib_posix.close(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0) return error.PtyUnavailable;
    const name = ptsname(master) orelse return error.PtyUnavailable;
    const slave = try lib_posix.open(std.mem.span(name), .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer lib_posix.close(slave);
    var tio: cross.termios = undefined;
    if (cross.tcgetattr(slave, &tio) != 0) return error.PtyUnavailable;
    cross.cfmakeraw(&tio);
    if (cross.tcsetattr(slave, cross.TCSANOW, &tio) != 0) return error.PtyUnavailable;
    var ws = std.mem.zeroes(cross.struct_winsize);
    ws.ws_row = rows;
    ws.ws_col = cols;
    if (cross.ioctl(master, cross.TIOCSWINSZ, &ws) != 0) return error.PtyUnavailable;
    return .{ master, slave };
}

/// A real daemonLoop on a thread, with one client the test holds over a socket pair of fixed buffer sizes.
/// The test can hand that socket to a real client loop whose terminal is a PTY the test reads, or not.
const EndingSession = struct {
    const start_mark = "DRAIN-START-MARK\n";
    const final_mark = "DRAIN-FINAL-MARK\n";
    const term_cols = 101;

    alloc: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    cfg: Cfg,
    daemon: Daemon,
    server_fd: i32,
    /// [0] the daemon's master, [1] the shell's side
    shell_pty: [2]i32,
    /// [0] what the terminal reads, [1] the client's stdin and stdout
    term_pty: [2]i32,
    sock: i32,
    /// with `peer`: a second client of the session, which the test reads itself; or -1
    peer: i32 = -1,
    saved_signals: SavedClientSignals,
    saved_sigpipe: lib_posix.Sigaction = undefined,
    /// the self-pipe daemonLoop opened, which a client loop replaces in `signal.sig_pipe`
    daemon_pipe: [2]lib_posix.fd_t = .{ -1, -1 },
    daemon_thread: std.Thread,
    client_thread: ?std.Thread = null,
    daemon_done_ms: std.atomic.Value(i64) = .init(0),
    client_done_ms: std.atomic.Value(i64) = .init(0),
    client_result: anyerror!ClientResult = error.NotRun,
    exit_ms: i64 = 0,

    const Options = struct {
        /// the daemon's drain deadline; long where a test does not measure it, so a starved runner meets it
        drain_ms: i64,
        /// the session gets a second client on `peer`, which never sends anything
        peer: bool = false,
    };

    fn start(self: *EndingSession, alloc: std.mem.Allocator, opts: Options) !void {
        self.* = .{
            .alloc = alloc,
            .tmp = std.testing.tmpDir(.{}),
            .cfg = .{ .socket_dir = "", .log_dir = "" },
            .daemon = undefined,
            .server_fd = undefined,
            .shell_pty = try testPty(24, 80),
            .term_pty = try testPty(33, term_cols),
            .sock = -1,
            .saved_signals = SavedClientSignals.save(),
            .daemon_thread = undefined,
        };
        lib_posix.sigaction(lib_posix.SIG.PIPE, null, &self.saved_sigpipe);
        signal.ignoreSigpipe(); // as main does: the client writes to a daemon that may be gone
        const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/s", .{self.tmp.sub_path});
        self.daemon = Daemon.init(std.testing.io, &self.cfg, "drain-test", path);
        self.server_fd = try socket.createSocket(path);
        const flags = try lib_posix.fcntl(self.shell_pty[0], lib_posix.F.GETFL, 0);
        _ = try lib_posix.fcntl(self.shell_pty[0], lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);
        // the session socket is a pair whose sizes the test sets, so no host default decides what the
        // daemon keeps; the daemon's end is a client as an accept would make it
        var pair: [2]i32 = undefined;
        if (std.c.socketpair(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM, 0, &pair) != 0) return error.NoSocketPair;
        for (pair) |fd| setBuffers(fd);
        _ = try lib_posix.fcntl(pair[0], lib_posix.F.SETFL, lib_posix.O_NONBLOCK);
        try self.daemon.clients.append(alloc, try testClient(alloc, pair[0], false));
        self.sock = pair[1];
        if (opts.peer) {
            var second: [2]i32 = undefined;
            if (std.c.socketpair(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM, 0, &second) != 0) return error.NoSocketPair;
            for (second) |fd| setBuffers(fd);
            _ = try lib_posix.fcntl(second[0], lib_posix.F.SETFL, lib_posix.O_NONBLOCK);
            try self.daemon.clients.append(alloc, try testClient(alloc, second[0], false));
            self.peer = second[1];
        }
        test_exit_drain_ms = opts.drain_ms;
        self.daemon_thread = try std.Thread.spawn(.{}, runDaemon, .{self});
        errdefer self.kill();

        const size = ipc.Resize{ .rows = 33, .cols = term_cols };
        try ipc.send(self.sock, .Init, std.mem.asBytes(&size));
        // the daemon sizes its PTY from its leader's Init, after it opened its self-pipe
        const deadline = nowMs() + 10_000;
        while (true) : (sleepMs(5)) {
            var ws: cross.struct_winsize = undefined;
            if (cross.ioctl(self.shell_pty[1], cross.TIOCGWINSZ, &ws) == 0 and ws.ws_col == term_cols) break;
            if (nowMs() > deadline) return error.NeverAttached;
        }
        self.daemon_pipe = signal.sig_pipe;
    }

    fn setBuffers(fd: i32) void {
        const size: c_int = 8192;
        for ([_]u32{ std.c.SO.SNDBUF, std.c.SO.RCVBUF }) |opt| {
            _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, opt, std.mem.asBytes(&size), @sizeOf(c_int));
        }
    }

    fn runDaemon(self: *EndingSession) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        daemonLoop(&self.daemon, self.alloc, threaded.io(), self.server_fd, self.shell_pty[0]) catch |err| {
            std.debug.panic("daemonLoop failed: {s}", .{@errorName(err)});
        };
        // as run's teardown does: the socket goes before the clients
        const path = lib_posix.toPosixPath(self.daemon.socket_path) catch unreachable;
        _ = std.c.unlink(&path);
        self.daemon.shutdown(self.alloc);
        self.daemon_done_ms.store(nowMs(), .release);
    }

    /// Hands the session socket to a client loop; the terminal reads nothing until the test does.
    fn attachClient(self: *EndingSession) !void {
        self.client_thread = try std.Thread.spawn(.{}, runClient, .{self});
    }

    fn runClient(self: *EndingSession) void {
        self.client_result = clientLoopWithFds(self.sock, "", self.term_pty[1], self.term_pty[1]);
        self.client_done_ms.store(nowMs(), .release);
    }

    /// The shell prints the start mark, `payload` and the final mark, and exits; returns once the daemon
    /// has read the exit, which it shows by no longer answering a LabelGet while it still answers an Info, or
    /// by being gone.
    fn shellPrintsAndExits(self: *EndingSession, payload: []const u8) !void {
        for ([_][]const u8{ start_mark, payload, final_mark }) |part| {
            var rest = part;
            while (rest.len > 0) rest = rest[try lib_posix.write(self.shell_pty[1], rest)..];
        }
        lib_posix.close(self.shell_pty[1]);
        self.shell_pty[1] = -1;
        defer self.exit_ms = nowMs();
        const probe = socket.sessionConnect(self.daemon.socket_path) catch return;
        defer lib_posix.close(probe);
        var replies = try ipc.SocketBuffer.init(self.alloc);
        defer replies.deinit();
        const deadline = nowMs() + 20_000;
        while (true) : (sleepMs(10)) {
            ipc.send(probe, .LabelGet, "") catch return;
            ipc.send(probe, .Info, "") catch return;
            var answered = false;
            info: while (true) {
                if ((replies.read(probe) catch return) == 0) return;
                while (replies.next()) |msg| switch (msg.header.tag) {
                    .LabelData => answered = true,
                    .Info => break :info,
                    else => {},
                };
            }
            if (!answered) return;
            if (nowMs() > deadline) return error.NeverDrained;
        }
    }

    /// Fills the client's terminal, so the client can write nothing until the test reads; returns how much.
    fn fillTerminal(self: *EndingSession) !usize {
        const fd = self.term_pty[1];
        const flags = try lib_posix.fcntl(fd, lib_posix.F.GETFL, 0);
        _ = try lib_posix.fcntl(fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);
        defer _ = lib_posix.fcntl(fd, lib_posix.F.SETFL, flags) catch {};
        var n: usize = 0;
        while (true) n += lib_posix.write(fd, "x") catch break;
        return n;
    }

    fn queued(fd: i32) usize {
        var n: c_int = 0;
        if (cross.ioctl(fd, cross.FIONREAD, &n) != 0) return 0;
        return @intCast(n);
    }

    fn done(flag: *const std.atomic.Value(i64)) bool {
        return flag.load(.acquire) != 0;
    }

    fn waitFor(flag: *const std.atomic.Value(i64)) void {
        const deadline = nowMs() + 40_000;
        while (!done(flag)) : (sleepMs(5)) {
            if (nowMs() > deadline) std.debug.panic("an ending session's loop did not finish in 40 s", .{});
        }
    }

    fn kill(self: *EndingSession) void {
        if (!done(&self.daemon_done_ms)) {
            if (socket.sessionConnect(self.daemon.socket_path)) |fd| {
                ipc.send(fd, .Kill, "") catch {};
                lib_posix.close(fd);
            } else |_| {}
        }
        self.daemon_thread.join();
        if (self.client_thread) |t| t.join();
        self.client_thread = null;
    }

    fn deinit(self: *EndingSession) void {
        const attached = self.client_thread != null;
        self.kill();
        if (!attached and self.sock >= 0) lib_posix.close(self.sock);
        if (self.peer >= 0) lib_posix.close(self.peer);
        test_exit_drain_ms = EXIT_DRAIN_MS;
        // a client loop closed its own self-pipe; the daemon's is closed here
        for (self.daemon_pipe) |fd| {
            if (fd >= 0) lib_posix.close(fd);
        }
        for (self.shell_pty ++ self.term_pty) |fd| {
            if (fd >= 0) lib_posix.close(fd);
        }
        lib_posix.close(self.server_fd);
        self.daemon.deinit(self.alloc);
        self.alloc.free(self.daemon.socket_path);
        self.tmp.cleanup();
        self.saved_signals.restore();
        lib_posix.sigaction(lib_posix.SIG.PIPE, &self.saved_sigpipe, null);
    }
};

/// The bounds are generous on purpose: a process a starved CI runner does not schedule cannot meet a
/// wall-clock deadline. What they need is that a loop ends on its deadline rather than early or never.
fn tookWithin(what: []const u8, took: i64, budget: i64, min: i64, max: i64) !void {
    if (took >= min and took <= max) return;
    std.debug.print("{s} took {d} ms on a {d} ms deadline, outside {d}..{d}\n", .{ what, took, budget, min, max });
    return error.TestUnexpectedResult;
}

fn testPayload(alloc: std.mem.Allocator) ![]u8 {
    // several times what the session socket holds
    const payload = try alloc.alloc(u8, 48 * 1024);
    for (payload, 0..) |*b, i| b.* = if (i % 100 == 99) '\n' else 'a' + @as(u8, @intCast(i % 26));
    return payload;
}

// regression: the daemon freed the output a busy client had not been sent at the shell's exit
test "a session's last output reaches a terminal that resumes, through the daemon and the client" {
    const alloc = std.testing.allocator;
    var s: EndingSession = undefined;
    try s.start(alloc, .{ .drain_ms = 20_000 });
    defer s.deinit();
    const payload = try testPayload(alloc);
    defer alloc.free(payload);
    const filled = try s.fillTerminal();

    try s.shellPrintsAndExits(payload);
    // the client was behind when the shell exited: the socket holds output it has not read
    try std.testing.expect(EndingSession.queued(s.sock) > 0);
    try s.attachClient();
    EndingSession.waitFor(&s.daemon_done_ms);

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var buf: [65536]u8 = undefined;
    const limit = nowMs() + 40_000;
    while (true) {
        var pfd = [_]lib_posix.pollfd{.{ .fd = s.term_pty[0], .events = lib_posix.POLL.IN, .revents = 0 }};
        _ = try lib_posix.poll(&pfd, 100);
        if (pfd[0].revents & lib_posix.POLL.IN != 0) {
            try got.appendSlice(alloc, buf[0..try lib_posix.read(s.term_pty[0], &buf)]);
        } else if (EndingSession.done(&s.client_done_ms)) break;
        if (nowMs() > limit) return error.ReaderTimedOut;
    }
    const expected = try std.mem.concat(alloc, u8, &.{ EndingSession.start_mark, payload, EndingSession.final_mark });
    defer alloc.free(expected);
    if (!std.mem.endsWith(u8, got.items, expected) or got.items.len != filled + expected.len) {
        std.debug.print("the terminal got {d} bytes after the {d} it was filled with, of {d} the shell wrote\n", .{ got.items.len -| filled, filled, expected.len });
        return error.TestUnexpectedResult;
    }
}

test "an ending session whose terminal never reads again ends the daemon and then the client on their deadlines" {
    const alloc = std.testing.allocator;
    var s: EndingSession = undefined;
    try s.start(alloc, .{ .drain_ms = EXIT_DRAIN_MS });
    defer s.deinit();
    const payload = try testPayload(alloc);
    defer alloc.free(payload);
    _ = try s.fillTerminal();

    try s.shellPrintsAndExits(payload);
    EndingSession.waitFor(&s.daemon_done_ms);
    // measured from when the test saw the exit, which lags the daemon's own reading of it
    try tookWithin("daemon", s.daemon_done_ms.load(.acquire) - s.exit_ms, EXIT_DRAIN_MS, EXIT_DRAIN_MS / 2, EXIT_DRAIN_MS + 10_000);
    const attached = nowMs();
    try s.attachClient();
    EndingSession.waitFor(&s.client_done_ms);
    try tookWithin("client", s.client_done_ms.load(.acquire) - attached, DRAIN_BUDGET_MS, DRAIN_BUDGET_MS - 500, DRAIN_BUDGET_MS + 10_000);
    try std.testing.expectEqual(.detach, (try s.client_result).kind);
}

test "a draining session takes no attach, input or command, and a kill ends it at once" {
    const alloc = std.testing.allocator;
    var s: EndingSession = undefined;
    try s.start(alloc, .{ .drain_ms = 20_000 });
    defer s.deinit();
    const payload = try testPayload(alloc);
    defer alloc.free(payload);

    try s.shellPrintsAndExits(payload);
    try std.testing.expect(!EndingSession.done(&s.daemon_done_ms));
    const late = try socket.sessionConnect(s.daemon.socket_path);
    defer lib_posix.close(late);
    const size = ipc.Resize{ .rows = 24, .cols = 80 };
    try ipc.send(late, .Init, std.mem.asBytes(&size));
    try ipc.send(late, .Input, "echo late\r");
    try ipc.send(late, .Run, "echo late");
    var pfd = [_]lib_posix.pollfd{.{ .fd = late, .events = lib_posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try lib_posix.poll(&pfd, 300));

    try ipc.send(late, .Kill, "");
    const sent = nowMs();
    EndingSession.waitFor(&s.daemon_done_ms);
    try std.testing.expect(s.daemon_done_ms.load(.acquire) - sent < @divTrunc(test_exit_drain_ms, 2));
}

/// Collects one client's frames until EOF, on its own thread.
const FrameReader = struct {
    alloc: std.mem.Allocator,
    fd: i32,
    frames: ipc.SocketBuffer,
    output: std.ArrayList(u8) = .empty,
    final_seen: std.atomic.Value(bool) = .init(false),
    eof_ms: std.atomic.Value(i64) = .init(0),

    fn run(self: *FrameReader) void {
        while (true) {
            const n = self.frames.read(self.fd) catch 0;
            if (n == 0) break;
            while (self.frames.next()) |msg| switch (msg.header.tag) {
                .Output => {
                    self.output.appendSlice(self.alloc, msg.payload) catch @panic("out of memory");
                    if (std.mem.endsWith(u8, self.output.items, EndingSession.final_mark)) self.final_seen.store(true, .release);
                },
                else => {},
            };
        }
        self.eof_ms.store(nowMs(), .release);
    }

    fn deinit(self: *FrameReader) void {
        self.output.deinit(self.alloc);
        self.frames.deinit();
    }
};

// a client the drain had sent everything and closed early could be told the session was gone, and reattach
// to it, while a peer was still behind; the teardown closes every client after the socket file is gone
test "a client sent everything waits for the teardown while a peer behind at the exit gets its last output" {
    const alloc = std.testing.allocator;
    var s: EndingSession = undefined;
    try s.start(alloc, .{ .drain_ms = 20_000, .peer = true });
    defer s.deinit();
    const payload = try testPayload(alloc);
    defer alloc.free(payload);

    var ahead: FrameReader = .{ .alloc = alloc, .fd = s.peer, .frames = try ipc.SocketBuffer.init(alloc) };
    defer ahead.deinit();
    const ahead_thread = try std.Thread.spawn(.{}, FrameReader.run, .{&ahead});
    defer ahead_thread.join();

    try s.shellPrintsAndExits(payload);
    // the reading client has been sent everything; give a drain that would let it go time to do so
    const seen_by = nowMs() + 20_000;
    while (!ahead.final_seen.load(.acquire)) : (sleepMs(5)) {
        if (nowMs() > seen_by) return error.ReaderNeverDone;
    }
    sleepMs(500);
    try std.testing.expect(!EndingSession.done(&s.daemon_done_ms));
    try std.testing.expectEqual(@as(i64, 0), ahead.eof_ms.load(.acquire));

    var behind: FrameReader = .{ .alloc = alloc, .fd = s.sock, .frames = try ipc.SocketBuffer.init(alloc) };
    defer behind.deinit();
    // on its own thread under the watchdog, so a daemon that never closes the client fails the test
    const behind_thread = try std.Thread.spawn(.{}, FrameReader.run, .{&behind});
    EndingSession.waitFor(&behind.eof_ms);
    behind_thread.join();
    EndingSession.waitFor(&s.daemon_done_ms);

    const expected = try std.mem.concat(alloc, u8, &.{ EndingSession.start_mark, payload, EndingSession.final_mark });
    defer alloc.free(expected);
    if (!std.mem.endsWith(u8, behind.output.items, expected)) {
        std.debug.print("the client behind read {d} output bytes, of {d} the shell wrote\n", .{ behind.output.items.len, expected.len });
        return error.TestUnexpectedResult;
    }
}
