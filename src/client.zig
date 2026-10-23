//! libzmx - programmatic client interface for zmx IPC.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");

pub const has_daemon = if (@hasDecl(build_options, "has_daemon")) build_options.has_daemon else true;

const ipc = @import("ipc.zig");
const socket = @import("socket.zig");
const Cfg = @import("cfg.zig");
const util = @import("util.zig");
const label = @import("label.zig");
const lib_posix = @import("posix.zig");
const cross = @import("cross.zig");
const signal = @import("signal.zig");
const loop = @import("loop.zig");
const Daemon = if (has_daemon) loop.Daemon else struct {};

pub const HistoryFormat = util.HistoryFormat;
pub const SessionEntry = util.SessionEntry;

pub const CreateOptions = struct {
    command: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    is_task_mode: bool = false,
    quiet: bool = false,
};

pub const AttachOptions = struct {
    command: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    tracked_env: ?[]const u8 = null,
};

pub const RunOptions = struct {
    detached: bool = false,
    cwd: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    stdin_bytes: ?[]const u8 = null,
    output_writer: ?*Io.Writer = null,
};

pub const KillOptions = struct {
    force: bool = false,
};

/// Ensure a session daemon is running in the background without attaching.
/// Resolves socket_dir and session prefix automatically.
/// If the session does not exist yet, forks the daemon internally (and exits
/// the daemon child process when the session ends so it never returns to caller).
/// Returns true if a new session was created, false if it already existed.
pub fn create(alloc: Allocator, io: Io, name: []const u8, opts: CreateOptions) !bool {
    if (!has_daemon) @compileError("create() requires -Ddaemon=true");
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const exists = try socket.sessionExists(io, dir, sesh);
    var should_create = !exists;
    if (exists) {
        if (ipc.connectSession(socket_path)) |fd| {
            lib_posix.close(fd);
            return false;
        } else |err| switch (err) {
            error.ConnectionRefused => {
                socket.cleanupStaleSocket(io, dir, sesh);
                should_create = true;
            },
            else => return false,
        }
    }

    if (!should_create) return false;

    var daemon = Daemon.init(io, &cfg, sesh, socket_path);
    daemon.command = opts.command;
    if (opts.cwd) |cwd| daemon.setCwd(cwd);
    if (opts.shell) |sh| daemon.shell = sh;
    daemon.is_task_mode = opts.is_task_mode;
    daemon.quiet = opts.quiet;

    const is_daemon_proc = try daemon.ensureSession(io);
    if (is_daemon_proc) {
        std.process.exit(0);
    }

    if (opts.labels) |kvs| {
        try set(alloc, io, sesh, kvs);
    }

    return true;
}

/// Connect to an existing session's Unix domain socket and return the socket fd.
pub fn connect(alloc: Allocator, io: Io, name: []const u8) !i32 {
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    return socket.sessionConnect(socket_path);
}

/// Attach the current process's stdin/stdout TTY to a session (creating if needed).
pub fn attach(alloc: Allocator, io: Io, name: []const u8, opts: AttachOptions) !void {
    signal.ignoreSigpipe();
    const cur_sesh = socket.getSeshNameFromEnv();
    if (cur_sesh.len > 0) {
        var cfg = try Cfg.init(alloc, io);
        defer cfg.deinit(alloc);
        const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, cur_sesh);
        defer alloc.free(socket_path);
        const fd = try socket.sessionConnect(socket_path);
        defer lib_posix.close(fd);
        const target_sesh = try socket.getSeshName(alloc, name);
        defer alloc.free(target_sesh);
        ipc.send(fd, .Switch, target_sesh) catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => return,
            else => return err,
        };
        return;
    }

    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    if (has_daemon) {
        var daemon = Daemon.init(io, &cfg, sesh, socket_path);
        daemon.command = opts.command;
        if (opts.cwd) |cwd| daemon.setCwd(cwd);
        if (opts.shell) |sh| daemon.shell = sh;
        const is_daemon_proc = try daemon.ensureSession(io);
        if (is_daemon_proc) std.process.exit(0);
    }

    if (opts.labels) |kvs| {
        try set(alloc, io, sesh, kvs);
    }

    const client_sock = try socket.sessionConnect(socket_path);

    var orig_termios: cross.c.termios = undefined;
    const stdin_is_tty = cross.c.tcgetattr(lib_posix.STDIN_FILENO, &orig_termios) == 0;
    const restore_seq = "\x1bc\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\";

    defer {
        if (stdin_is_tty) {
            _ = cross.c.tcsetattr(lib_posix.STDIN_FILENO, cross.c.TCSAFLUSH, &orig_termios);
        }
        _ = lib_posix.write(lib_posix.STDOUT_FILENO, restore_seq) catch {};
    }

    if (stdin_is_tty) {
        var raw_termios = orig_termios;
        cross.c.cfmakeraw(&raw_termios);
        raw_termios.c_cc[cross.c.VLNEXT] = cross.c._POSIX_VDISABLE;
        raw_termios.c_cc[cross.c.VQUIT] = cross.c._POSIX_VDISABLE;
        raw_termios.c_cc[cross.c.VMIN] = 1;
        raw_termios.c_cc[cross.c.VTIME] = 0;
        _ = cross.c.tcsetattr(lib_posix.STDIN_FILENO, cross.c.TCSANOW, &raw_termios);
    }

    const clear_seq = "\x1b[0m\x1b[2J\x1b[H";
    _ = try lib_posix.write(lib_posix.STDOUT_FILENO, clear_seq);

    const env_str = opts.tracked_env orelse "";
    const looper = try loop.clientLoop(client_sock, env_str);
    switch (looper.kind) {
        .detach => return,
        .switch_session => {
            if (looper.session_name) |target_name| {
                _ = lib_posix.write(lib_posix.STDOUT_FILENO, restore_seq) catch {};
                var new_opts = opts;
                if (looper.cwd) |new_cwd| new_opts.cwd = new_cwd;
                return attach(alloc, io, target_name, new_opts);
            }
        },
    }
}

/// Detach all clients from the specified session (or current ZMX_SESSION if "." or empty).
pub fn detach(alloc: Allocator, io: Io, name: []const u8) !void {
    signal.ignoreSigpipe();
    const raw_name = if (name.len == 0 or std.mem.eql(u8, name, "."))
        socket.getSeshNameFromEnv()
    else
        name;
    if (raw_name.len == 0) return error.SessionNameRequired;

    const sesh = try socket.getSeshName(alloc, raw_name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const fd = ipc.connectSession(socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, sesh);
        return error.SessionUnresponsive;
    };
    defer lib_posix.close(fd);

    ipc.send(fd, .DetachAll, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

/// List all active sessions. Caller owns the returned slice and entries.
pub fn list(alloc: Allocator, io: Io) ![]SessionEntry {
    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    var sessions = try util.get_session_entries(alloc, io, cfg.socket_dir);
    return sessions.toOwnedSlice(alloc);
}

pub const KillStatus = enum {
    killed,
    cleaned_stale,
};

/// Kill a session and wait for its socket to close.
pub fn kill(alloc: Allocator, io: Io, name: []const u8, opts: KillOptions) !KillStatus {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const exists = try socket.sessionExists(io, dir, sesh);
    if (!exists) return error.SessionNotFound;

    const fd = ipc.connectSession(socket_path) catch |err| {
        if (opts.force or err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(io, dir, sesh);
            return .cleaned_stale;
        }
        return error.SessionUnresponsive;
    };
    defer lib_posix.close(fd);

    ipc.send(fd, .Kill, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return .killed,
        else => return err,
    };

    var drain: [256]u8 = undefined;
    while (true) {
        const n = lib_posix.read(fd, &drain) catch break;
        if (n == 0) break;
    }
    return .killed;
}

fn tailInternal(
    alloc: Allocator,
    client_socket_fds: []const i32,
    detached: bool,
    is_run_cmd: bool,
    writer: ?*Io.Writer,
) !u8 {
    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(alloc, client_socket_fds.len + 1);
    defer poll_fds.deinit(alloc);

    var read_buf = try ipc.SocketBuffer.init(alloc);
    defer read_buf.deinit();

    var out_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer out_buf.deinit(alloc);

    var is_first_line = true;
    var task_complete_code: ?u8 = null;

    while (true) {
        poll_fds.clearRetainingCapacity();

        for (client_socket_fds) |fd| {
            try poll_fds.append(alloc, .{
                .fd = fd,
                .events = lib_posix.POLL.IN,
                .revents = 0,
            });
        }

        if (out_buf.items.len > 0 and writer == null) {
            try poll_fds.append(alloc, .{
                .fd = lib_posix.STDOUT_FILENO,
                .events = lib_posix.POLL.OUT,
                .revents = 0,
            });
        }

        _ = lib_posix.poll(poll_fds.items, -1) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };

        for (poll_fds.items) |*poll_fd| {
            if (poll_fd.revents & lib_posix.POLL.IN != 0) {
                const n = read_buf.read(poll_fd.fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) return 1;
                    return err;
                };
                if (n == 0) {
                    if (task_complete_code) |exit_code| return exit_code;
                    return 0;
                }

                while (read_buf.next()) |msg| {
                    switch (msg.header.tag) {
                        .Ack => {
                            if (detached) {
                                if (writer) |w| {
                                    try w.writeAll("command sent!\n");
                                } else {
                                    _ = lib_posix.write(lib_posix.STDOUT_FILENO, "command sent!\n") catch {};
                                }
                                return 0;
                            }
                        },
                        .Output => {
                            if (msg.payload.len > 0) {
                                var payload = msg.payload;
                                if (!detached and is_run_cmd and is_first_line) {
                                    if (std.mem.indexOfScalar(u8, payload, '\n')) |nl| {
                                        is_first_line = false;
                                        payload = payload[nl + 1 ..];
                                    } else {
                                        is_first_line = false;
                                        payload = payload[payload.len..];
                                    }
                                }

                                if (payload.len > 0) {
                                    const plain = util.stripAnsi(alloc, payload) catch continue;
                                    defer alloc.free(plain);
                                    if (plain.len > 0) {
                                        if (writer) |w| {
                                            try w.writeAll(plain);
                                        } else {
                                            try out_buf.appendSlice(alloc, plain);
                                        }
                                    }
                                }
                            }
                        },
                        .TaskComplete => {
                            task_complete_code = if (msg.payload.len > 0) msg.payload[0] else 0;
                        },
                        else => {},
                    }
                }
            }
        }

        if (task_complete_code) |exit_code| {
            if (writer == null) {
                while (out_buf.items.len > 0) {
                    const n = lib_posix.write(lib_posix.STDOUT_FILENO, out_buf.items) catch break;
                    try out_buf.replaceRange(alloc, 0, n, &[_]u8{});
                }
            }
            return exit_code;
        }

        if (writer == null and out_buf.items.len > 0) {
            const n = lib_posix.write(lib_posix.STDOUT_FILENO, out_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (n > 0) {
                try out_buf.replaceRange(alloc, 0, n, &[_]u8{});
            }
        }

        for (poll_fds.items) |poll_fd| {
            if (poll_fd.revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
                return 0;
            }
        }
    }
}

/// Run a command inside a session in task mode (creating if needed).
/// Returns the command's exit code (or 0 immediately if `opts.detached` is true).
pub fn run(
    alloc: Allocator,
    io: Io,
    name: []const u8,
    command: []const []const u8,
    opts: RunOptions,
) !u8 {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    if (has_daemon) {
        var daemon = Daemon.init(io, &cfg, sesh, socket_path);
        daemon.is_task_mode = true;
        if (opts.cwd) |cwd| daemon.setCwd(cwd);
        if (opts.shell) |sh| daemon.shell = sh;
        const is_daemon_proc = try daemon.ensureSession(io);
        if (is_daemon_proc) std.process.exit(0);
    }

    var cmd_to_send: ?[]const u8 = null;
    var allocated_cmd: ?[]u8 = null;
    defer if (allocated_cmd) |c| alloc.free(c);

    if (command.len > 0) {
        var cmd_list = std.ArrayList(u8).empty;
        defer cmd_list.deinit(alloc);

        for (command, 0..) |arg, i| {
            if (i > 0) try cmd_list.append(alloc, ' ');
            if (util.shellNeedsQuoting(arg)) {
                const quoted = try util.shellQuote(alloc, arg);
                defer alloc.free(quoted);
                try cmd_list.appendSlice(alloc, quoted);
            } else {
                try cmd_list.appendSlice(alloc, arg);
            }
        }
        try cmd_list.append(alloc, '\r');
        cmd_to_send = try cmd_list.toOwnedSlice(alloc);
        allocated_cmd = @constCast(cmd_to_send.?);
    } else if (opts.stdin_bytes) |bytes| {
        if (bytes.len > 0) {
            var buf = try std.ArrayList(u8).initCapacity(alloc, bytes.len + 1);
            defer buf.deinit(alloc);
            try buf.appendSlice(alloc, bytes);
            if (buf.items[buf.items.len - 1] == '\n') {
                buf.items[buf.items.len - 1] = '\r';
            } else {
                try buf.append(alloc, '\r');
            }
            cmd_to_send = try buf.toOwnedSlice(alloc);
            allocated_cmd = @constCast(cmd_to_send.?);
        }
    }

    if (cmd_to_send == null) return error.CommandRequired;

    const client_sock = try socket.sessionConnect(socket_path);
    defer lib_posix.close(client_sock);

    const term_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
    ipc.send(client_sock, .Resize, std.mem.asBytes(&term_size)) catch {};

    ipc.send(client_sock, .Run, cmd_to_send.?) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return 0,
        else => return err,
    };

    const fds = [_]i32{client_sock};
    return tailInternal(alloc, &fds, opts.detached, true, opts.output_writer);
}

/// Wait for one or more task-mode sessions to complete and return aggregate exit code.
pub fn wait(alloc: Allocator, io: Io, names: []const []const u8) !u8 {
    if (names.len == 0) return error.SessionNameRequired;
    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    var matchers = try std.ArrayList(socket.SessionMatch).initCapacity(alloc, names.len);
    defer {
        for (matchers.items) |m| alloc.free(m.name);
        matchers.deinit(alloc);
    }
    for (names) |name| {
        try matchers.append(alloc, try socket.parseSessionArg(alloc, name));
    }

    var agg_exit_code: u8 = 0;
    while (true) {
        agg_exit_code = 0;
        var sessions = try util.get_session_entries(alloc, io, cfg.socket_dir);
        defer {
            for (sessions.items) |s| s.deinit(alloc);
            sessions.deinit(alloc);
        }

        var total: usize = 0;
        var done: usize = 0;

        for (sessions.items) |session| {
            var matched = false;
            for (matchers.items) |m| {
                if (m.matches(session.name)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
            total += 1;
            if (session.is_error) {
                agg_exit_code = 1;
                done += 1;
            } else if (session.task_ended_at != null) {
                if (session.task_exit_code) |ec| {
                    if (ec != 0) agg_exit_code = ec;
                }
                done += 1;
            }
        }

        if (total > 0 and done == total) return agg_exit_code;
        std.time.sleep(50 * std.time.ns_per_ms);
    }
}

/// Follow live output from one or more sessions, writing plain text to `writer`.
pub fn tail(alloc: Allocator, io: Io, names: []const []const u8, writer: ?*Io.Writer) !u8 {
    if (names.len == 0) return error.SessionNameRequired;
    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    var matchers = try std.ArrayList(socket.SessionMatch).initCapacity(alloc, names.len);
    defer {
        for (matchers.items) |m| alloc.free(m.name);
        matchers.deinit(alloc);
    }
    for (names) |name| {
        try matchers.append(alloc, try socket.parseSessionArg(alloc, name));
    }

    var resolved_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (resolved_names.items) |n| alloc.free(n);
        resolved_names.deinit(alloc);
    }

    var any_prefix = false;
    for (matchers.items) |m| {
        if (m.is_prefix) {
            any_prefix = true;
            break;
        }
    }

    if (any_prefix) {
        var sessions = try util.get_session_entries(alloc, io, cfg.socket_dir);
        defer {
            for (sessions.items) |s| s.deinit(alloc);
            sessions.deinit(alloc);
        }
        for (sessions.items) |s| {
            for (matchers.items) |m| {
                if (m.matches(s.name)) {
                    try resolved_names.append(alloc, try alloc.dupe(u8, s.name));
                    break;
                }
            }
        }
    }

    for (matchers.items) |m| {
        if (!m.is_prefix) {
            try resolved_names.append(alloc, try alloc.dupe(u8, m.name));
        }
    }

    if (resolved_names.items.len == 0) return error.SessionNotFound;

    var fds = try std.ArrayList(i32).initCapacity(alloc, resolved_names.items.len);
    defer {
        for (fds.items) |fd| lib_posix.close(fd);
        fds.deinit(alloc);
    }

    for (resolved_names.items) |session_name| {
        const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, session_name);
        defer alloc.free(socket_path);
        const sock = try socket.sessionConnect(socket_path);
        try fds.append(alloc, sock);
    }

    return tailInternal(alloc, fds.items, false, false, writer);
}

/// Send raw input bytes to a session's PTY (fire-and-forget, like `zmx send`).
pub fn send(alloc: Allocator, io: Io, name: []const u8, bytes: []const u8) !void {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const probe_result = ipc.probeSession(alloc, socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, sesh);
        return error.SessionUnresponsive;
    };
    defer probe_result.deinit();

    ipc.send(probe_result.fd, .Send, bytes) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };
}

/// Inject raw bytes directly into a session's display/scrollback (like `zmx print`).
pub fn print(alloc: Allocator, io: Io, name: []const u8, bytes: []const u8) !void {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const probe_result = ipc.probeSession(alloc, socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, sesh);
        return error.SessionUnresponsive;
    };
    defer probe_result.deinit();

    ipc.send(probe_result.fd, .Output, bytes) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };
}

/// Write `content` to `remote_path` inside the session (like `zmx write`).
pub fn write(alloc: Allocator, io: Io, name: []const u8, remote_path: []const u8, content: []const u8) !void {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const result = ipc.probeSession(alloc, socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, sesh);
        return error.SessionUnresponsive;
    };
    defer result.deinit();

    var wire_buf = try std.ArrayList(u8).initCapacity(alloc, @sizeOf(u32) + remote_path.len + content.len);
    defer wire_buf.deinit(alloc);
    const path_len: u32 = @intCast(remote_path.len);
    try wire_buf.appendSlice(alloc, std.mem.asBytes(&path_len));
    try wire_buf.appendSlice(alloc, remote_path);
    try wire_buf.appendSlice(alloc, content);

    ipc.send(result.fd, .Write, wire_buf.items) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    const n = sb.read(result.fd) catch return error.ReadFailed;
    if (n == 0) return error.ConnectionClosed;

    while (sb.next()) |msg| {
        if (msg.header.tag == .Ack) return;
    }
    return error.NoAckReceived;
}

/// Fetch session scrollback with optional row count.
pub fn historyRange(alloc: Allocator, io: Io, name: []const u8, format: HistoryFormat, scrollback_rows: ?u32) ![]u8 {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const exists = try socket.sessionExists(io, dir, sesh);
    if (!exists) return error.SessionNotFound;

    const fd = ipc.connectSession(socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, sesh);
        return error.SessionUnresponsive;
    };
    defer lib_posix.close(fd);

    const reply_tag: ipc.Tag = if (scrollback_rows != null) .Capture else .History;
    if (scrollback_rows) |rows| {
        var request = std.mem.zeroes(ipc.Capture);
        request.format = @intFromEnum(format);
        request.rows = rows;
        try ipc.send(fd, .Capture, std.mem.asBytes(&request));
        try ipc.send(fd, .Info, "");
    } else {
        const format_byte = [_]u8{@intFromEnum(format)};
        try ipc.send(fd, .History, &format_byte);
    }

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    while (true) {
        var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        const poll_result = lib_posix.poll(&poll_fds, 5000) catch return error.Timeout;
        if (poll_result == 0) return error.Timeout;

        const n = sb.read(fd) catch return error.ReadFailed;
        if (n == 0) return error.ConnectionClosed;

        while (sb.next()) |msg| {
            if (msg.header.tag == reply_tag) {
                return alloc.dupe(u8, msg.payload);
            }
            if (scrollback_rows != null and msg.header.tag == .Info) {
                return error.CaptureNotSupported;
            }
        }
    }
}

/// Fetch session scrollback in `.plain`, `.vt`, or `.html` format. Caller owns slice.
pub fn history(alloc: Allocator, io: Io, name: []const u8, format: HistoryFormat) ![]u8 {
    return historyRange(alloc, io, name, format, null);
}

/// Get session labels (all `k=v` pairs if `key == null`, or single value). Caller owns slice.
pub fn get(alloc: Allocator, io: Io, name: []const u8, key: ?[]const u8) ![]u8 {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    const payload = try ipc.roundTripForTag(alloc, socket_path, .LabelGet, "", .LabelData);
    errdefer alloc.free(payload);

    if (key == null) return payload;

    const val = try label.getLabelValueFromPairs(key.?, payload);
    const result = try alloc.dupe(u8, val);
    alloc.free(payload);
    return result;
}

/// Set or unset (`k=`) space-separated session labels.
pub fn set(alloc: Allocator, io: Io, name: []const u8, kvs: []const u8) !void {
    signal.ignoreSigpipe();
    var it = label.LabelIterator.init(kvs);
    while (it.next()) |kv| {
        try label.assertLabel(kv.key, kv.value);
    }

    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    _ = try ipc.roundTripForTag(alloc, socket_path, .LabelSet, kvs, .Ack);
}

/// Clear all labels on a session.
pub fn clear(alloc: Allocator, io: Io, name: []const u8) !void {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    _ = try ipc.roundTripForTag(alloc, socket_path, .LabelClear, "", .Ack);
}

/// Get tracked environment variables for the session leader (`zmx print-env`).
pub fn printEnv(alloc: Allocator, io: Io, name: []const u8, key: ?[]const u8) ![]u8 {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    const payload = try ipc.roundTripForTag(alloc, socket_path, .EnvGet, "", .EnvData);

    // A whole-environment query gives this buffer to the caller.
    if (key == null) return payload;
    defer alloc.free(payload);

    // Search for key in payload: lines formatted as "KEY=VALUE\n"
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, key.?)) {
            if (line.len > key.?.len and line[key.?.len] == '=') {
                const val = line[key.?.len + 1 ..];
                return try alloc.dupe(u8, val);
            }
        }
    }
    return error.EnvVarNotFound;
}
