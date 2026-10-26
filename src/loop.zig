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
const program_status = @import("program_status.zig");

/// clientLoop sends ipc commands to its corresponding daemon.  It uses poll() as its non-blocking
/// mechanism. It will send stdin to the daemon and receive stdout from the daemon.
pub fn clientLoop(client_sock_fd: i32, env_str: []const u8) !ClientResult {
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
    const size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
    try ipc.appendMessage(gpa, &sock_write_buf, .Init, std.mem.asBytes(&size));

    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(gpa, 4);
    defer poll_fds.deinit(gpa);

    var read_buf = try ipc.SocketBuffer.init(gpa);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer stdout_buf.deinit(gpa);

    const stdin_fd = lib_posix.STDIN_FILENO;

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
                .fd = lib_posix.STDOUT_FILENO,
                .events = lib_posix.POLL.OUT,
                .revents = 0,
            });
        }

        _ = try lib_posix.poll(poll_fds.items, -1);

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            signal.drainSignalPipe();
            const next_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
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
                    return ClientResult{ .kind = .detach, .session_name = null };
                }
                std.log.err("daemon read err={s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) {
                std.log.info("server closed connection", .{});
                // Server closed connection
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
                        const next_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
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
            const n = lib_posix.write(lib_posix.STDOUT_FILENO, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (n > 0) {
                try stdout_buf.replaceRange(gpa, 0, n, &[_]u8{});
            }
        }

        if (poll_fds.items[1].revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
            std.log.info("poll hup|err|nval", .{});
            return ClientResult{ .kind = .detach, .session_name = null };
        }
    }
}

fn initTerminal(gpa: std.mem.Allocator, io: std.Io, size: ipc.Resize, cfg: *const Cfg) !ghostty_vt.Terminal {
    return ghostty_vt.Terminal.init(io, gpa, .{
        .cols = size.cols,
        .rows = size.rows,
        .max_scrollback_lines = cfg.max_scrollback_lines,
        .max_scrollback_bytes = null, // Let the line limit control scrollback.
    });
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
    daemon.initVtStream(gpa, &term);
    const vt_stream = &daemon.vt_stream;
    defer vt_stream.deinit();

    // Carries the tail of the previous PTY read so the task-exit marker
    // search below can see across a read() boundary. Sized to comfortably
    // hold "ZMX_TASK_COMPLETED:" (19 bytes) plus a u8 exit code and CRLF.
    var marker_carry: [32]u8 = undefined;
    var marker_carry_len: usize = 0;

    var had_terminal_client = daemon.hasTerminalClient();

    daemon_loop: while (daemon.running) {
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
        try poll_fds.append(gpa, .{
            .fd = pty_fd,
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

        _ = try lib_posix.poll(poll_fds.items, -1);

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            signal.drainSignalPipe();
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
                    // Let the rest of this poll iteration complete so client
                    // write buffers are flushed via the normal POLLOUT path.
                    // On the next iteration, daemon.running will be false.
                    daemon.program_status_records.removeWorkingAndBlocked(gpa);
                    daemon.running = false;
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
                    switch (msg.header.tag) {
                        .Input => try daemon.handleInput(gpa, client, msg.payload),
                        .Send => daemon.handleSend(gpa, msg.payload),
                        .Output => try daemon.handleOutput(gpa, msg.payload, &term, vt_stream),
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
    program_status_records: program_status.Records = .{},
    // Initialized and deinitialized by 'daemonLoop' while its terminal is alive.
    vt_stream: ghostty_vt.TerminalStream = undefined,
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
        self.program_status_records.deinit(gpa);
        self.pty_write_buf.deinit(gpa);
        gpa.free(self.socket_path);
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

    /// Connect Ghostty's OSC 7501 and shell-prompt callbacks to this daemon's records.
    /// Keep the daemon at a fixed address until its stream is deinitialized.
    fn initVtStream(self: *Daemon, alloc: std.mem.Allocator, term: *ghostty_vt.Terminal) void {
        const Callbacks = struct {
            fn onProgramStatus(handler: *@FieldType(ghostty_vt.TerminalStream, "handler"), report: ghostty_vt.osc.Command.ProgramStatus.Report) void {
                const daemon = fromVtHandler(handler);
                daemon.program_status_records.updateFromReport(handler.terminal.gpa(), report) catch |err| {
                    std.log.warn("failed to retain program status: {s}", .{@errorName(err)});
                };
            }

            fn onTerminalReply(handler: *@FieldType(ghostty_vt.TerminalStream, "handler"), data: []const u8) void {
                const daemon = fromVtHandler(handler);
                if (daemon.hasTerminalClient()) return;

                // Ghostty also produces replies for other terminal protocols.
                // Only answer OSC 7501 here so their existing handling stays intact.
                const reply = "\x1b]7501;" ++ ghostty_vt.osc.program_status.query_reply;
                if (!std.mem.eql(u8, data, reply ++ "\x07") and
                    !std.mem.eql(u8, data, reply ++ "\x1b\\")) return;

                // Ghostty has already built the OSC 7501 support reply in 'data'.
                // Send it back to the program while no terminal is attached so the
                // program can start reporting before a terminal connects.
                // www.superlogical.com/rex/docs/build/program-status#feature-detection
                daemon.queuePtyInput(handler.terminal.gpa(), data);
            }

            fn onSemanticPrompt(handler: *@FieldType(ghostty_vt.TerminalStream, "handler"), event: ghostty_vt.SemanticPrompt) void {
                const daemon = fromVtHandler(handler);
                if (event.kind == .prompt_start) {
                    daemon.program_status_records.removeWorkingAndBlocked(handler.terminal.gpa());
                }
            }
        };

        self.vt_stream = .init(.{
            .allocator = alloc,
            .handler = term.vtHandler(),
            // A reconnect can happen halfway through an OSC 7501 message.
            // Save enough bytes for the spec's whole-sequence limit.
            // "4096 bytes. The largest legal report is under 3300."
            // www.superlogical.com/rex/docs/build/program-status#limits
            .continuation_max_bytes = ghostty_vt.osc.program_status.max_sequence_bytes,
        });

        // While attached, the outer terminal owns capability replies. Both the
        // parser callback and attachment changes run in this daemon's event loop.
        self.vt_stream.handler.effects.write_pty = &Callbacks.onTerminalReply;
        self.vt_stream.handler.effects.program_status = &Callbacks.onProgramStatus;
        self.vt_stream.handler.effects.semantic_prompt = &Callbacks.onSemanticPrompt;
    }

    fn fromVtHandler(handler: *@FieldType(ghostty_vt.TerminalStream, "handler")) *Daemon {
        // Ghostty passes the handler inside our stream to these callbacks.
        // Follow the containing fields back to the daemon that owns the records.
        const stream: *ghostty_vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("vt_stream", stream);
    }

    /// Write OSC 7501 messages restoring saved task records, then any unfinished
    /// terminal message. Call after restoring the screen and before sending new
    /// output so the next bytes finish the message the program had already started.
    /// Buffer this output before sending it and discard it if writing fails.
    fn writeProgramStatus(self: *const Daemon, writer: *std.Io.Writer) !void {
        try self.program_status_records.writeReplay(writer);
        // Even if we could not save all OSC 7501 reports, continue any unfinished live
        // message. Ghostty leaves out actions it already performed, so reading
        // the saved bytes does not repeat them.
        self.vt_stream.writeContinuation(writer) catch |err| switch (err) {
            // Other terminal messages can exceed the OSC 7501 sequence limit.
            // If Ghostty could not save one, keep the screen and OSC 7501 restoration.
            error.ContinuationUnavailable => std.log.warn("unfinished terminal sequence unavailable on reattach", .{}),
            else => return err,
        };
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

        self.restoreClient(gpa, client, term) catch |err| {
            std.log.warn("failed to buffer program status for client err={s}", .{@errorName(err)});
        };

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

    /// Restore this attaching client's screen and saved OSC 7501 Program Status.
    fn restoreClient(self: *Daemon, gpa: std.mem.Allocator, client: *Client, term: *ghostty_vt.Terminal) !void {
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
        // Restore saved OSC 7501 Program Status records for this reconnecting client.
        // Include any unfinished terminal message so later live output can finish it.
        // Build these messages separately so failure preserves queued screen output.
        var replay: std.Io.Writer.Allocating = .init(gpa);
        defer replay.deinit();
        try self.writeProgramStatus(&replay.writer);
        if (replay.writer.buffered().len == 0) return;

        // 'appendMessage' reserves space for all prepared bytes before adding any.
        // If allocation fails, no OSC 7501 'clear' or saved task reports are queued.
        try ipc.appendMessage(gpa, &client.write_buf, .Output, replay.writer.buffered());
        client.has_pending_output = true;
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

/// A daemon and terminal for testing OSC 7501 Program Status without starting a shell.
const TestProgramSession = struct {
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };

    daemon: Daemon = testDaemon(),
    term: ghostty_vt.Terminal = undefined,
    stream: *ghostty_vt.TerminalStream = undefined,
    records: *program_status.Records = undefined,

    /// Initialize in place because the stream keeps pointers to our fields.
    fn init(self: *TestProgramSession) !void {
        self.term = try initTerminal(std.testing.allocator, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
        self.daemon.initVtStream(std.testing.allocator, &self.term);
        self.stream = &self.daemon.vt_stream;
        self.records = &self.daemon.program_status_records;
    }

    fn deinit(self: *TestProgramSession) void {
        self.stream.deinit();
        self.term.deinit(std.testing.allocator);
        self.daemon.program_status_records.deinit(std.testing.allocator);
        self.daemon.pty_write_buf.deinit(std.testing.allocator);
        self.daemon.clients.deinit(std.testing.allocator);
    }

    fn report(self: *TestProgramSession, data: []const u8) void {
        self.stream.nextSlice("\x1b]7501;");
        self.stream.nextSlice(data);
        self.stream.nextSlice("\x1b\\");
    }

    fn writeReplay(self: *const TestProgramSession, writer: *std.Io.Writer) !void {
        try self.daemon.writeProgramStatus(writer);
    }
};

/// Owns a test client and both pipe ends so cleanup also runs after an assertion fails.
/// Tests that register this client with a daemon must leave closing it to this helper.
const TestProgramClient = struct {
    client: *Client,
    peer_fd: i32,

    fn init(is_terminal: bool) !TestProgramClient {
        const pipes = try lib_posix.pipe2(.{});
        errdefer lib_posix.close(pipes[0]);
        errdefer lib_posix.close(pipes[1]);
        return .{ .client = try testClient(std.testing.allocator, pipes[0], is_terminal), .peer_fd = pipes[1] };
    }

    fn deinit(self: *TestProgramClient) void {
        self.client.deinit(std.testing.allocator);
        std.testing.allocator.destroy(self.client);
        lib_posix.close(self.peer_fd);
    }
};

fn repeatTestBytes(comptime bytes: []const u8, comptime count: usize) [bytes.len * count]u8 {
    var result: [bytes.len * count]u8 = undefined;
    for (0..count) |index| {
        @memcpy(result[index * bytes.len ..][0..bytes.len], bytes);
    }
    return result;
}

/// Feed only queued terminal output to the receiving terminal and count its messages.
fn replayTestOutput(client: *const Client, target: *ghostty_vt.TerminalStream) !usize {
    var messages = try ipc.SocketBuffer.init(std.testing.allocator);
    defer messages.deinit();
    try messages.buf.appendSlice(std.testing.allocator, client.write_buf.items);
    var outputs: usize = 0;
    while (messages.next()) |message| {
        if (message.header.tag == .Output) {
            outputs += 1;
            target.nextSlice(message.payload);
        }
    }
    return outputs;
}

test "program status reattachment restores root and children and removes stale records" {
    const alloc = std.testing.allocator;
    var session: TestProgramSession = .{};
    try session.init();
    defer session.deinit();
    const daemon = &session.daemon;
    const term = &session.term;
    const stream = session.stream;
    try daemon.handleOutput(alloc, "screen text\x1b]7501;state=idle:app=agent\x07\x1b]7501;state=blocked:id=worker:kind=permission\x07", term, stream);

    var connection = try TestProgramClient.init(false);
    defer connection.deinit();
    const client = connection.client;
    const size = ipc.Resize{ .rows = 24, .cols = 80 };
    try daemon.handleInit(alloc, client, -1, term, std.mem.asBytes(&size));

    var receiver: TestProgramSession = .{};
    try receiver.init();
    defer receiver.deinit();
    const target = &receiver.term;
    const target_records = receiver.records;
    const target_stream = receiver.stream;
    target_stream.nextSlice("\x1b]7501;state=working\x07\x1b]7501;state=error:id=stale\x07");
    _ = try replayTestOutput(client, target_stream);
    try std.testing.expectEqual(@as(usize, 2), target_records.items.items.len);
    try std.testing.expectEqual(.idle, target_records.get(null).?.state);
    try std.testing.expectEqualStrings("agent", target_records.get(null).?.readOption(.app).?);
    try std.testing.expectEqual(.blocked, target_records.get("worker").?.state);
    try std.testing.expectEqual(.permission, target_records.get("worker").?.readOption(.kind).?);
    try std.testing.expect(target_records.get("stale") == null);
    const screen = try target.plainString(alloc);
    defer alloc.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "screen text") != null);
}

test "program status reattachment clears an empty session before any output" {
    const alloc = std.testing.allocator;
    var session: TestProgramSession = .{};
    try session.init();
    defer session.deinit();
    const daemon = &session.daemon;
    const term = &session.term;
    var connection = try TestProgramClient.init(false);
    defer connection.deinit();
    const client = connection.client;
    const size = ipc.Resize{ .rows = 24, .cols = 80 };
    try daemon.handleInit(alloc, client, -1, term, std.mem.asBytes(&size));
    try std.testing.expect(std.mem.indexOf(u8, client.write_buf.items, "\x1b]7501;state=clear\x1b\\") != null);
}

test "program status repeated attachment is private and precedes later live output" {
    const alloc = std.testing.allocator;
    var session: TestProgramSession = .{};
    try session.init();
    defer session.deinit();
    const daemon = &session.daemon;
    const term = &session.term;
    const stream = session.stream;
    daemon.pid = std.math.maxInt(i32);
    try daemon.handleOutput(alloc, "\x1b]7501;state=working\x07", term, stream);
    const pipes = try lib_posix.pipe2(.{});
    const first = try testClient(alloc, pipes[0], true);
    defer alloc.destroy(first);
    defer first.deinit(alloc);
    const second = try testClient(alloc, pipes[1], true);
    defer alloc.destroy(second);
    defer second.deinit(alloc);
    try daemon.clients.append(alloc, first);
    try daemon.clients.append(alloc, second);
    daemon.leader_client_fd = first.socket_fd;
    const size = ipc.Resize{ .rows = 24, .cols = 80 };
    try daemon.handleInit(alloc, second, -1, term, std.mem.asBytes(&size));
    const once = try alloc.dupe(u8, second.write_buf.items);
    defer alloc.free(once);
    try daemon.handleInit(alloc, second, -1, term, std.mem.asBytes(&size));
    try std.testing.expectEqualStrings(once, second.write_buf.items[once.len..]);
    try std.testing.expectEqual(@as(usize, 0), first.write_buf.items.len);
    const update = "\x1b]7501;state=idle\x07";
    try daemon.handleOutput(alloc, update, term, stream);
    try std.testing.expectEqualStrings(update, first.write_buf.items[@sizeOf(ipc.Header)..]);
    var receiver: TestProgramSession = .{};
    try receiver.init();
    defer receiver.deinit();
    const records = receiver.records;
    const target_stream = receiver.stream;
    const outputs = try replayTestOutput(second, target_stream);
    try std.testing.expectEqual(@as(usize, 5), outputs);
    try std.testing.expectEqual(@as(usize, 1), records.items.items.len);
    try std.testing.expectEqual(.idle, records.get(null).?.state);
}

test "program status attachment restores screen before unfinished parser state" {
    const alloc = std.testing.allocator;
    const cases = .{
        .{ "\x1b]7501;state=blocked:id=worker:kind=permission", "\x07" },
        .{ "\xe2\x82", "\xac" },
        .{ "\x1b[3", "1mZ" },
    };
    inline for (cases) |case| {
        var session: TestProgramSession = .{};
        try session.init();
        defer session.deinit();
        const daemon = &session.daemon;
        const term = &session.term;
        const stream = session.stream;
        daemon.pid = std.math.maxInt(i32);
        try daemon.handleOutput(alloc, "screen text", term, stream);
        try daemon.handleOutput(alloc, case[0], term, stream);
        var connection = try TestProgramClient.init(true);
        defer connection.deinit();
        const client = connection.client;
        try daemon.clients.append(alloc, client);
        daemon.leader_client_fd = client.socket_fd;
        const size = ipc.Resize{ .rows = 24, .cols = 80 };
        try daemon.handleInit(alloc, client, -1, term, std.mem.asBytes(&size));
        try daemon.handleOutput(alloc, case[1], term, stream);
        var receiver: TestProgramSession = .{};
        try receiver.init();
        defer receiver.deinit();
        const target = &receiver.term;
        const records = receiver.records;
        const target_stream = receiver.stream;
        _ = try replayTestOutput(client, target_stream);
        const expected = try term.plainString(alloc);
        defer alloc.free(expected);
        const actual = try target.plainString(alloc);
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
        if (std.mem.startsWith(u8, case[0], "\x1b]7501")) {
            try std.testing.expectEqual(.blocked, records.get("worker").?.state);
            try std.testing.expectEqual(.permission, records.get("worker").?.readOption(.kind).?);
        }
    }
}

test "program status failed replay never queues a partial snapshot or changes pending output" {
    const alloc = std.testing.allocator;
    var session: TestProgramSession = .{};
    try session.init();
    defer session.deinit();
    const daemon = &session.daemon;
    const term = &session.term;
    const stream = session.stream;
    stream.nextSlice("\x1b]7501;state=working\x07");
    // Leave the screen empty so allocation failures exercise both building the
    // OSC 7501 restoration messages and adding them to the client's output buffer.
    // A prior queued message must survive.
    var failures: usize = 0;
    for ([_]bool{ false, true }) |pending| {
        var reached_success = false;
        for (0..20) |fail_index| {
            var connection = try TestProgramClient.init(true);
            defer connection.deinit();
            const client = connection.client;
            try client.write_buf.appendSlice(alloc, "existing output");
            // Fill the client output buffer so adding the OSC 7501 messages
            // for this reconnecting client must allocate more memory.
            try client.write_buf.appendNTimes(alloc, 'x', client.write_buf.capacity - client.write_buf.items.len);
            const before = try alloc.dupe(u8, client.write_buf.items);
            defer alloc.free(before);
            client.has_pending_output = pending;
            var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index, .resize_fail_index = 0 });
            daemon.restoreClient(failing.allocator(), client, term) catch {
                failures += 1;
                try std.testing.expectEqualStrings(before, client.write_buf.items);
                try std.testing.expectEqual(pending, client.has_pending_output);
                continue;
            };
            try std.testing.expect(client.has_pending_output);
            try std.testing.expect(std.mem.startsWith(u8, client.write_buf.items, before));
            try std.testing.expect(std.mem.indexOf(u8, client.write_buf.items, "state=working") != null);
            reached_success = true;
            break;
        }
        try std.testing.expect(reached_success);
    }
    try std.testing.expect(failures >= 4);
}

test "program status allocation failure preserves an already restored screen" {
    const alloc = std.testing.allocator;
    var session: TestProgramSession = .{};
    try session.init();
    defer session.deinit();
    const daemon = &session.daemon;
    const term = &session.term;
    const stream = session.stream;
    stream.nextSlice("screen remains available\x1b]7501;state=working\x07");
    daemon.has_pty_output = true;

    var preserved_screen_on_failure = false;
    var reached_success = false;
    for (0..64) |fail_index| {
        var connection = try TestProgramClient.init(true);
        defer connection.deinit();
        const client = connection.client;
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        daemon.restoreClient(failing.allocator(), client, term) catch {
            if (client.write_buf.items.len > 0) {
                // Keep screen output even if restoring OSC 7501 Program Status
                // failed. Do not send 'clear' without the saved task reports.
                try std.testing.expect(std.mem.indexOf(u8, client.write_buf.items, "screen remains available") != null);
                try std.testing.expect(std.mem.indexOf(u8, client.write_buf.items, "\x1b]7501;") == null);
                try std.testing.expect(client.has_pending_output);
                preserved_screen_on_failure = true;
            }
            continue;
        };
        try std.testing.expect(std.mem.indexOf(u8, client.write_buf.items, "screen remains available") != null);
        try std.testing.expect(std.mem.indexOf(u8, client.write_buf.items, "state=working") != null);
        reached_success = true;
        break;
    }
    try std.testing.expect(reached_success);
    try std.testing.expect(preserved_screen_on_failure);
}

test "program status unavailable recovery metadata still restores the screen" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |lost_records| {
        var session: TestProgramSession = .{};
        try session.init();
        defer session.deinit();
        const daemon = &session.daemon;
        const term = &session.term;
        const stream = session.stream;
        stream.nextSlice("screen survives\x1b]7501;state=blocked\x07");
        daemon.has_pty_output = true;
        if (lost_records) {
            var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
            try std.testing.expectError(error.OutOfMemory, daemon.program_status_records.updateFromReport(failing.allocator(), .{ .state = .idle, .data = "state=idle" }));
        } else {
            stream.nextSlice("\x1b]52;c;" ++ repeatTestBytes("YQ==", 1100));
        }
        var connection = try TestProgramClient.init(true);
        defer connection.deinit();
        const client = connection.client;
        try daemon.restoreClient(alloc, client, term);
        var receiver: TestProgramSession = .{};
        try receiver.init();
        defer receiver.deinit();
        const target = &receiver.term;
        const records = receiver.records;
        const target_stream = receiver.stream;
        _ = try replayTestOutput(client, target_stream);
        const screen = try target.plainString(alloc);
        defer alloc.free(screen);
        try std.testing.expect(std.mem.indexOf(u8, screen, "screen survives") != null);
        if (lost_records) {
            try std.testing.expectEqual(@as(usize, 0), records.items.items.len);
            try std.testing.expect(std.mem.indexOf(u8, client.write_buf.items, "7501") == null);
        } else {
            try std.testing.expectEqual(.blocked, records.get(null).?.state);
        }
    }
}

test "program status collection and forwarding survive client attachment changes" {
    const alloc = std.testing.allocator;
    var session: TestProgramSession = .{};
    try session.init();
    defer session.deinit();
    const daemon = &session.daemon;
    // Close clients left attached if an assertion interrupts the detach checks.
    defer while (daemon.clients.items.len > 0) {
        _ = daemon.closeClient(alloc, daemon.clients.items[0], 0, false);
    };
    const term = &session.term;
    const stream = session.stream;

    try daemon.handleOutput(alloc, "\x1b]7501;?\x07\x1b]7501;state=working\x07", term, stream);
    try std.testing.expectEqual(.working, daemon.program_status_records.get(null).?.state);
    try std.testing.expectEqualStrings("\x1b]7501;" ++ ghostty_vt.osc.program_status.query_reply ++ "\x07", daemon.pty_write_buf.items);
    daemon.pty_write_buf.clearRetainingCapacity();

    const pipes = try lib_posix.pipe2(.{});
    const first = try testClient(alloc, pipes[0], true);
    try daemon.clients.append(alloc, first);
    const second = try testClient(alloc, pipes[1], true);
    try daemon.clients.append(alloc, second);
    // Do not signal a real process group from 'handleOutput' in this unit test.
    daemon.pid = std.math.maxInt(i32);
    const update = "\x1b]7501;?\x07\x1b]7501;state=blocked:kind=permission\x07";
    try daemon.handleOutput(alloc, update, term, stream);
    try std.testing.expectEqual(.blocked, daemon.program_status_records.get(null).?.state);
    try std.testing.expectEqual(@as(usize, 0), daemon.pty_write_buf.items.len);
    try std.testing.expectEqualStrings(update, first.write_buf.items[@sizeOf(ipc.Header)..]);
    try std.testing.expectEqualStrings(update, second.write_buf.items[@sizeOf(ipc.Header)..]);

    _ = daemon.closeClient(alloc, first, 0, false);
    try daemon.handleOutput(alloc, "\x1b]7501;?\x07", term, stream);
    try std.testing.expectEqual(@as(usize, 0), daemon.pty_write_buf.items.len);
    _ = daemon.closeClient(alloc, second, 0, false);
    try daemon.handleOutput(alloc, "\x1b]7501;?\x07\x1b]7501;state=done\x07", term, stream);
    try std.testing.expectEqual(.done, daemon.program_status_records.get(null).?.state);
    try std.testing.expectEqualStrings("\x1b]7501;" ++ ghostty_vt.osc.program_status.query_reply ++ "\x07", daemon.pty_write_buf.items);
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

test "program status owns reports and replaces complete records" {
    var f: TestProgramSession = .{};
    try f.init();
    defer f.deinit();

    // Deliberately split escape sequences across reads, including the terminator.
    f.stream.nextSlice("\x1b]");
    f.stream.nextSlice("7501;state=blocked:app=claude-code:kind=permission:msg=QXBwcm92ZT8=\x1b");
    f.stream.nextSlice("\\");
    f.report("state=working:id=worker:progress=37");
    try std.testing.expectEqual(.blocked, f.records.get(null).?.state);
    try std.testing.expectEqualStrings("claude-code", f.records.get(null).?.readOption(.app).?);
    try std.testing.expectEqual(.permission, f.records.get(null).?.readOption(.kind).?);
    try std.testing.expectEqual(@as(u8, 37), f.records.get("worker").?.readOption(.progress).?);

    f.report("state=idle");
    const root = f.records.get(null).?;
    try std.testing.expectEqual(.idle, root.state);
    try std.testing.expect(root.readOption(.app) == null);
    try std.testing.expect(root.readOption(.kind) == null);
    try std.testing.expect(root.readOption(.msg) == null);
    try std.testing.expectEqual(@as(usize, 2), f.records.items.items.len);
}

test "program status clears descendants at path boundaries without requiring a parent" {
    var f: TestProgramSession = .{};
    try f.init();
    defer f.deinit();
    f.report("state=idle");
    f.report("state=blocked:id=build/test:kind=question");
    f.report("state=working:id=builder/test");
    f.report("state=clear:id=build");
    try std.testing.expect(f.records.get("build/test") == null);
    try std.testing.expect(f.records.get("builder/test") != null);
    try std.testing.expect(f.records.get(null) != null);
    f.report("state=clear");
    try std.testing.expectEqual(@as(usize, 0), f.records.items.items.len);
}

test "program status lifetimes distinguish prompts screens soft resets and full resets" {
    var f: TestProgramSession = .{};
    try f.init();
    defer f.deinit();
    f.report("state=working");
    f.report("state=blocked:id=blocked");
    f.report("state=done:id=done");
    f.report("state=error:id=error");
    f.report("state=idle:id=idle");
    f.stream.nextSlice("\x1b[?1049h\x1b[?1049l\x1b[!p");
    try std.testing.expectEqual(@as(usize, 5), f.records.items.items.len);
    f.stream.nextSlice("\x1b]133;A\x07");
    try std.testing.expect(f.records.get(null) == null);
    try std.testing.expect(f.records.get("blocked") == null);
    try std.testing.expectEqual(@as(usize, 3), f.records.items.items.len);

    f.report("state=working");
    f.records.removeWorkingAndBlocked(std.testing.allocator);
    try std.testing.expect(f.records.get(null) == null);
    try std.testing.expect(f.records.get("done") != null);
    f.stream.nextSlice("\x1bc");
    try std.testing.expectEqual(@as(usize, 0), f.records.items.items.len);
}

test "program status rejects malformed and oversized reports atomically" {
    var f: TestProgramSession = .{};
    try f.init();
    defer f.deinit();
    f.report("state=done:app=test");
    const invalid = [_][]const u8{
        "state=unknown",
        "state=blocked:id=bad//id",
        "state=blocked:msg=A",
        "state=blocked:msg=Cg==", // newline
        "state=blocked:title=wog=", // C1 control U+0088
        "state=blocked:abcdefghijklmnopq=x",
        "state=blocked:app=" ++ repeatTestBytes("a", 33),
        "state=blocked:msg=" ++ repeatTestBytes("YQ==", 684),
        "state=blocked:title=" ++ repeatTestBytes("YQ==", 65),
        "state=blocked:unknown=" ++ repeatTestBytes("x", 4096),
    };
    for (invalid) |data| {
        f.report(data);
        try std.testing.expectEqualStrings("test", f.records.get(null).?.readOption(.app).?);
        try std.testing.expectEqual(.done, f.records.get(null).?.state);
        try std.testing.expectEqual(@as(usize, 1), f.records.items.items.len);
    }
}

test "program status records with the same id are isolated between sessions" {
    var first: TestProgramSession = .{};
    try first.init();
    defer first.deinit();
    var second: TestProgramSession = .{};
    try second.init();
    defer second.deinit();
    first.report("state=blocked:id=worker");
    second.report("state=done:id=worker");
    first.report("state=clear");
    try std.testing.expectEqual(@as(usize, 0), first.records.items.items.len);
    try std.testing.expectEqual(.done, second.records.get("worker").?.state);
}

test "program status replay preserves every report split across attachment" {
    const alloc = std.testing.allocator;
    const sequences = [_][]const u8{
        "\x1b]7501;state=idle:app=agent:msg=UmVhZHk=\x07",
        "\x1b]7501;state=blocked:id=worker/test:kind=permission:progress=37\x1b\\",
        "\x1b]7501;state=clear:id=worker\x1b\\",
        "\x1b]7501;state=clear\x07",
    };
    for (sequences) |sequence| {
        for (0..sequence.len + 1) |cut| {
            var source: TestProgramSession = .{};
            try source.init();
            defer source.deinit();
            source.report("state=working:app=agent");
            source.report("state=working:id=worker/test");
            source.stream.nextSlice(sequence[0..cut]);

            var replay: std.Io.Writer.Allocating = .init(alloc);
            defer replay.deinit();
            try source.writeReplay(&replay.writer);
            var target: TestProgramSession = .{};
            try target.init();
            defer target.deinit();
            target.report("state=error:id=stale");
            target.stream.nextSlice(replay.writer.buffered());
            source.stream.nextSlice(sequence[cut..]);
            target.stream.nextSlice(sequence[cut..]);
            try std.testing.expectEqual(source.records.items.items.len, target.records.items.items.len);
            for (source.records.items.items) |record| {
                const restored = target.records.get(record.readOption(.id)) orelse return error.TestUnexpectedNull;
                try std.testing.expectEqual(record.state, restored.state);
                try std.testing.expectEqualStrings(record.data, restored.data);
            }
        }
    }
}

test "program status restores a large interrupted report through client attachment" {
    const alloc = std.testing.allocator;
    const id = repeatTestBytes("a", 31) ++ "/" ++ repeatTestBytes("b", 31) ++ "/" ++ repeatTestBytes("c", 31) ++ "/" ++ repeatTestBytes("d", 31);
    const report = "state=blocked:kind=permission:progress=100:app=" ++ repeatTestBytes("a", 32) ++
        ":id=" ++ id ++ ":title=" ++ repeatTestBytes("YWFh", 64) ++ ":msg=" ++ repeatTestBytes("YWFh", 682) ++ "YWE=";
    const sequence = "\x1b]7501;" ++ report ++ "\x1b\\";
    // Fill each text field to its protocol limit so reconnect exercises a large
    // unfinished OSC 7501 message.
    // www.superlogical.com/rex/docs/build/program-status#limits
    for ([_]usize{ 7, 1023, sequence.len - 2, sequence.len - 1, sequence.len }) |cut| {
        var source: TestProgramSession = .{};
        try source.init();
        defer source.deinit();
        source.report("state=working");
        try source.daemon.handleOutput(alloc, sequence[0..cut], &source.term, source.stream);

        var connection = try TestProgramClient.init(false);
        defer connection.deinit();
        try source.daemon.restoreClient(alloc, connection.client, &source.term);

        var receiver: TestProgramSession = .{};
        try receiver.init();
        defer receiver.deinit();
        receiver.report("state=error:id=stale");
        _ = try replayTestOutput(connection.client, receiver.stream);
        receiver.stream.nextSlice(sequence[cut..]);
        source.stream.nextSlice(sequence[cut..]);

        const restored = receiver.records.get(id) orelse return error.TestUnexpectedNull;
        try std.testing.expectEqual(.blocked, restored.state);
        try std.testing.expectEqualStrings(report, restored.data);
        try std.testing.expectEqualStrings(report, source.records.get(id).?.data);
        try std.testing.expectEqual(.working, receiver.records.get(null).?.state);
        try std.testing.expect(receiver.records.get("stale") == null);
        try std.testing.expectEqual(@as(usize, 2), receiver.records.items.items.len);
    }
}

test "program status replay continues pending queries without repeating dispatched queries" {
    const S = struct {
        fn reply(handler: *@FieldType(ghostty_vt.TerminalStream, "handler"), data: []const u8) void {
            const daemon = Daemon.fromVtHandler(handler);
            const session: *TestProgramSession = @fieldParentPtr("daemon", daemon);
            const target: *@This() = @fieldParentPtr("session", session);
            target.replies.appendSlice(std.testing.allocator, data) catch @panic("test allocation failed");
        }

        session: TestProgramSession = .{},
        replies: std.ArrayList(u8) = .empty,
    };
    const queries = [_][]const u8{ "\x1b]7501;?\x07", "\x1b]7501;?\x1b\\" };
    for (queries) |query| {
        for (0..query.len) |cut| {
            var source: TestProgramSession = .{};
            try source.init();
            defer source.deinit();
            source.stream.nextSlice(query[0..cut]);
            var replay: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer replay.deinit();
            try source.writeReplay(&replay.writer);
            var target: S = .{};
            try target.session.init();
            defer target.session.deinit();
            defer target.replies.deinit(std.testing.allocator);
            target.session.stream.handler.effects.write_pty = &S.reply;
            target.session.stream.nextSlice(replay.writer.buffered());
            try std.testing.expectEqual(@as(usize, 0), target.replies.items.len);
            target.session.stream.nextSlice(query[cut..]);
            // Ghostty considers the query complete when it reads the escape
            // byte of the two-byte terminator. Replaying the final backslash
            // must not process the same query again.
            const dispatched = query[query.len - 1] == '\\' and cut == query.len - 1;
            if (dispatched) {
                try std.testing.expectEqual(@as(usize, 0), target.replies.items.len);
            } else {
                const terminator: []const u8 = if (query[query.len - 1] == 7) "\x07" else "\x1b\\";
                var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer expected.deinit();
                try expected.writer.print("\x1b]7501;{s}{s}", .{ ghostty_vt.osc.program_status.query_reply, terminator });
                try std.testing.expectEqualStrings(expected.writer.buffered(), target.replies.items);
            }
        }
    }
}

test "program status replay stays unavailable after a missed update until root clear or reset" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "\x1b]7501;state=clear\x07", "\x1bc" }) |reset| {
        var f: TestProgramSession = .{};
        try f.init();
        defer f.deinit();
        f.report("state=working:app=agent");
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, f.records.updateFromReport(failing.allocator(), .{ .state = .idle, .data = "state=idle" }));
        f.report("state=done:id=worker");
        f.report("state=clear:id=worker");
        f.stream.nextSlice("\x1b]133;A\x07");
        var unavailable: std.Io.Writer.Allocating = .init(alloc);
        defer unavailable.deinit();
        try f.writeReplay(&unavailable.writer);
        try std.testing.expectEqual(@as(usize, 0), unavailable.writer.buffered().len);

        f.stream.nextSlice(reset);
        var recovered: std.Io.Writer.Allocating = .init(alloc);
        defer recovered.deinit();
        try f.writeReplay(&recovered.writer);
        try std.testing.expectEqualStrings("\x1b]7501;state=clear\x1b\\", recovered.writer.buffered());
    }
}

test "program status replay recovers after an oversized unrelated continuation" {
    var f: TestProgramSession = .{};
    try f.init();
    defer f.deinit();
    f.report("state=blocked:id=worker");
    f.stream.nextSlice("\x1b]52;c;" ++ repeatTestBytes("YQ==", 1100));
    var replay: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer replay.deinit();
    try f.writeReplay(&replay.writer);
    try std.testing.expectEqualStrings("\x1b]7501;state=clear\x1b\\\x1b]7501;state=blocked:id=worker\x1b\\", replay.writer.buffered());
    f.stream.nextSlice("\x07\x1b]7501;state=idle");
    replay.clearRetainingCapacity();
    try f.writeReplay(&replay.writer);
    try std.testing.expect(std.mem.endsWith(u8, replay.writer.buffered(), "\x1b]7501;state=idle"));
}

test "program status detached capability replies survive every query split" {
    const alloc = std.testing.allocator;
    inline for (.{ "\x07", "\x1b\\" }) |terminator| {
        const query = "\x1b]7501;?" ++ terminator;
        const expected = "\x1b]7501;" ++ ghostty_vt.osc.program_status.query_reply ++ terminator;
        for (0..query.len + 1) |cut| {
            var session: TestProgramSession = .{};
            try session.init();
            defer session.deinit();
            var control = try TestProgramClient.init(false);
            defer control.deinit();
            try session.daemon.clients.append(alloc, control.client);
            session.stream.nextSlice(query[0..cut]);
            session.stream.nextSlice(query[cut..]);
            try std.testing.expectEqualStrings(expected, session.daemon.pty_write_buf.items);
            try std.testing.expectEqual(@as(usize, 0), session.records.items.items.len);
        }
    }
}

test "program status capability ownership follows terminal attachment at query dispatch" {
    const alloc = std.testing.allocator;
    inline for (.{ "\x07", "\x1b\\" }) |terminator| {
        const query = "\x1b]7501;?" ++ terminator;
        const expected = "\x1b]7501;" ++ ghostty_vt.osc.program_status.query_reply ++ terminator;
        for ([_]bool{ false, true }) |initially_attached| {
            for (0..query.len + 1) |cut| {
                var session: TestProgramSession = .{};
                try session.init();
                defer session.deinit();
                var first = try TestProgramClient.init(initially_attached);
                defer first.deinit();
                var second = try TestProgramClient.init(initially_attached);
                defer second.deinit();
                try session.daemon.clients.append(alloc, first.client);
                try session.daemon.clients.append(alloc, second.client);
                session.stream.nextSlice(query[0..cut]);
                first.client.is_terminal = !initially_attached;
                second.client.is_terminal = !initially_attached;
                session.stream.nextSlice(query[cut..]);
                // Ghostty dispatches ST-ended queries at ESC, before the final
                // backslash. The terminal attachment at that point owns the reply.
                const dispatch_end = if (terminator.len == 2) query.len - 1 else query.len;
                const daemon_replies = if (cut >= dispatch_end) !initially_attached else initially_attached;
                try std.testing.expectEqualStrings(if (daemon_replies) expected else "", session.daemon.pty_write_buf.items);
            }
        }
    }
}

test "program status capability replies leave other terminal queries to existing handlers" {
    var session: TestProgramSession = .{};
    try session.init();
    defer session.deinit();
    session.stream.nextSlice("\x1b[c\x1b[>c\x1b[5n\x1b[6n\x1b]10;?\x07\x1b]52;c;?\x07");
    try std.testing.expectEqualStrings("", session.daemon.pty_write_buf.items);
    session.report("state=blocked:msg=cHJpdmF0ZQ==");
    session.stream.nextSlice("\x1b]7501;?\x07");
    try std.testing.expectEqualStrings("\x1b]7501;" ++ ghostty_vt.osc.program_status.query_reply ++ "\x07", session.daemon.pty_write_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, session.daemon.pty_write_buf.items, "private") == null);
}

test "program status detached capability reply precedes device attributes" {
    var session: TestProgramSession = .{};
    try session.init();
    defer session.deinit();
    const query = "\x1b]7501;?\x07\x1b[c";
    session.stream.nextSlice(query);
    util.respondToDeviceAttributes(std.testing.allocator, &session.daemon.pty_write_buf, query);
    try std.testing.expectEqualStrings("\x1b]7501;" ++ ghostty_vt.osc.program_status.query_reply ++ "\x07" ++ "\x1b[?62;22c", session.daemon.pty_write_buf.items);
}

test "program status does not repeat a query after its attached terminal leaves" {
    var session: TestProgramSession = .{};
    try session.init();
    defer session.deinit();
    var connection = try TestProgramClient.init(true);
    defer connection.deinit();
    try session.daemon.clients.append(std.testing.allocator, connection.client);
    session.stream.nextSlice("\x1b]7501;?\x1b\\");
    connection.client.is_terminal = false;
    var restored: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer restored.deinit();
    try session.writeReplay(&restored.writer);
    try std.testing.expectEqualStrings("\x1b]7501;state=clear\x1b\\", restored.writer.buffered());
    try std.testing.expectEqualStrings("", session.daemon.pty_write_buf.items);
    // A terminal can disconnect before answering. Only a new query can ask
    // again after that loss, rather than a later attachment repeating it.
    session.stream.nextSlice("\x1b]7501;?\x07");
    try std.testing.expectEqualStrings("\x1b]7501;" ++ ghostty_vt.osc.program_status.query_reply ++ "\x07", session.daemon.pty_write_buf.items);
}

test "program status capability reply never partially overwrites queued input" {
    var session: TestProgramSession = .{};
    try session.init();
    defer session.deinit();
    const alloc = std.testing.allocator;
    try session.daemon.pty_write_buf.appendNTimes(alloc, 'x', Daemon.PTY_WRITE_BUF_MAX - 1);
    session.stream.nextSlice("\x1b]7501;?\x07");
    try std.testing.expectEqual(Daemon.PTY_WRITE_BUF_MAX - 1, session.daemon.pty_write_buf.items.len);
    try std.testing.expect(std.mem.allEqual(u8, session.daemon.pty_write_buf.items, 'x'));
    session.daemon.pty_write_buf.clearRetainingCapacity();
    session.stream.nextSlice("\x1b]7501;?\x07");
    try std.testing.expectEqualStrings("\x1b]7501;" ++ ghostty_vt.osc.program_status.query_reply ++ "\x07", session.daemon.pty_write_buf.items);
}
