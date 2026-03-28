const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const build_options = @import("build_options");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const completions = @import("completions.zig");
const util = @import("util.zig");
const cross = @import("cross.zig");
const socket = @import("socket.zig");

pub const version = build_options.version;
pub const git_sha = build_options.git_sha;
pub const ghostty_version = build_options.ghostty_version;

var log_system = log.LogSystem{};

pub const std_options: std.Options = .{
    .logFn = zmxLogFn,
    .log_level = .debug,
};

fn zmxLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    log_system.log(level, scope, format, args);
}

var sigwinch_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var sigterm_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/std/posix.zig#L3505
const O_NONBLOCK: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");

pub fn main() !void {
    // use c_allocator to avoid "reached unreachable code" panic in DebugAllocator when forking
    const alloc = std.heap.c_allocator;

    // Every subcommand may write to a Unix-domain socket; a peer that
    // disappears between probe and send would otherwise kill us before
    // write() can return BrokenPipe. Inherited across fork, so this also
    // covers the daemon.
    ignoreSigpipe();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.skip(); // skip program name

    var cfg = try Cfg.init(alloc);
    defer cfg.deinit(alloc);

    const log_path = try std.fs.path.join(alloc, &.{ cfg.log_dir, "zmx.log" });
    defer alloc.free(log_path);
    try log_system.init(alloc, log_path);
    defer log_system.deinit();

    const cmd = args.next() orelse {
        return list(&cfg, false);
    };

    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "--version")) {
        return printVersion(&cfg);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "-h")) {
        return help();
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "l")) {
        const short = if (args.next()) |arg| std.mem.eql(u8, arg, "--short") else false;
        return list(&cfg, short);
    } else if (std.mem.eql(u8, cmd, "completions") or std.mem.eql(u8, cmd, "c")) {
        const arg = args.next() orelse return;
        const shell = completions.Shell.fromString(arg) orelse return;
        return printCompletions(shell);
    } else if (std.mem.eql(u8, cmd, "detach") or std.mem.eql(u8, cmd, "d")) {
        return detachAll(&cfg);
    } else if (std.mem.eql(u8, cmd, "history") or std.mem.eql(u8, cmd, "hi")) {
        var session_name: ?[]const u8 = null;
        var format: util.HistoryFormat = .plain;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--vt")) {
                format = .vt;
            } else if (std.mem.eql(u8, arg, "--html")) {
                format = .html;
            } else if (session_name == null) {
                session_name = arg;
            }
        }
        const sesh_env = socket.getSeshNameFromEnv();
        const sesh = try socket.getSeshName(alloc, session_name orelse sesh_env);
        defer alloc.free(sesh);
        return history(&cfg, sesh, format);
    } else if (std.mem.eql(u8, cmd, "attach") or std.mem.eql(u8, cmd, "a")) {
        const session_name = args.next() orelse "";

        var command_args: std.ArrayList([]const u8) = .empty;
        defer command_args.deinit(alloc);
        while (args.next()) |arg| {
            try command_args.append(alloc, arg);
        }

        const clients = try std.ArrayList(*Client).initCapacity(alloc, 10);
        var command: ?[][]const u8 = null;
        if (command_args.items.len > 0) {
            command = command_args.items;
        }

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch "";

        const sesh = try socket.getSeshName(alloc, session_name);
        defer alloc.free(sesh);
        var daemon = Daemon{
            .running = true,
            .cfg = &cfg,
            .alloc = alloc,
            .clients = clients,
            .session_name = sesh,
            .socket_path = undefined,
            .pid = undefined,
            .command = command,
            .cwd = cwd,
            .created_at = @intCast(std.time.timestamp()),
        };
        daemon.socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
            error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
            error.OutOfMemory => return err,
        };
        std.log.info("socket path={s}", .{daemon.socket_path});
        return attach(&daemon);
    } else if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "r")) {
        const session_name = args.next() orelse "";

        var cmd_args_raw: std.ArrayList([]const u8) = .empty;
        defer cmd_args_raw.deinit(alloc);
        while (args.next()) |arg| {
            try cmd_args_raw.append(alloc, arg);
        }
        const clients = try std.ArrayList(*Client).initCapacity(alloc, 10);

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch "";

        const sesh = try socket.getSeshName(alloc, session_name);
        defer alloc.free(sesh);
        var daemon = Daemon{
            .running = true,
            .cfg = &cfg,
            .alloc = alloc,
            .clients = clients,
            .session_name = sesh,
            .socket_path = undefined,
            .pid = undefined,
            .command = null,
            .cwd = cwd,
            .created_at = @intCast(std.time.timestamp()),
            .is_task_mode = true,
            .task_command = cmd_args_raw.items,
        };
        daemon.socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
            error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
            error.OutOfMemory => return err,
        };
        std.log.info("socket path={s}", .{daemon.socket_path});
        return run(&daemon, cmd_args_raw.items);
    } else if (std.mem.eql(u8, cmd, "kill") or std.mem.eql(u8, cmd, "k")) {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;

        var args_raw: std.ArrayList([]const u8) = .empty;
        defer {
            for (args_raw.items) |sesh| {
                alloc.free(sesh);
            }
            args_raw.deinit(alloc);
        }
        while (args.next()) |session_name| {
            const sesh = try socket.getSeshName(alloc, session_name);
            try args_raw.append(alloc, sesh);
        }
        // if no args are provided we assume they want to wait for all sessions matching the
        // prefix.
        if (args_raw.items.len == 0) {
            const prefix = socket.getSeshPrefix();
            if (prefix.len == 0) {
                return error.SessionNameRequired;
            }
            try args_raw.append(alloc, try alloc.dupe(u8, prefix));
        }
        var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
        defer {
            for (sessions.items) |session| {
                session.deinit(alloc);
            }
            sessions.deinit(alloc);
        }
        for (sessions.items) |session| {
            for (args_raw.items) |prefix| {
                if (std.mem.startsWith(u8, session.name, prefix)) {
                    kill(&cfg, session.name) catch |err| {
                        try stderr.print(
                            "failed to kill session={s}: {s}\n",
                            .{ session.name, @errorName(err) },
                        );
                        try stderr.flush();
                    };
                    break;
                }
            }
        }
        return;
    } else if (std.mem.eql(u8, cmd, "wait") or std.mem.eql(u8, cmd, "w")) {
        var args_raw: std.ArrayList([]const u8) = .empty;
        defer {
            for (args_raw.items) |sesh| {
                alloc.free(sesh);
            }
            args_raw.deinit(alloc);
        }
        while (args.next()) |session_name| {
            const sesh = try socket.getSeshName(alloc, session_name);
            try args_raw.append(alloc, sesh);
        }
        // if no args are provided we assume they want to wait for all sessions matching the
        // prefix.
        if (args_raw.items.len == 0) {
            const prefix = socket.getSeshPrefix();
            if (prefix.len == 0) {
                return error.SessionNameRequired;
            }
            try args_raw.append(alloc, prefix);
        }
        return wait(&cfg, args_raw);
    } else {
        return help();
    }
}

/// Client represents each terminal that has connected to a session.
///
/// Multiple Clients can connect to a single session.
const Client = struct {
    alloc: std.mem.Allocator,
    socket_fd: i32,
    has_pending_output: bool = false,
    read_buf: ipc.SocketBuffer,
    write_buf: std.ArrayList(u8),

    pub fn deinit(self: *Client) void {
        posix.close(self.socket_fd);
        self.read_buf.deinit();
        self.write_buf.deinit(self.alloc);
    }
};

/// Cfg is zmx's configuration container.
///
/// The purpose of this container is to hold anything that can be modified by the user.
const Cfg = struct {
    socket_dir: []const u8,
    log_dir: []const u8,
    max_scrollback: usize = 10_000_000,

    pub fn init(alloc: std.mem.Allocator) !Cfg {
        const socket_dir = try socketDir(alloc);
        const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{socket_dir});
        errdefer alloc.free(log_dir);

        var cfg = Cfg{
            .socket_dir = socket_dir,
            .log_dir = log_dir,
        };

        try cfg.mkdir();

        return cfg;
    }

    fn socketDir(alloc: std.mem.Allocator) ![]const u8 {
        const tmpdir = std.mem.trimRight(u8, posix.getenv("TMPDIR") orelse "/tmp", "/");
        const uid = posix.getuid();

        const socket_dir: []const u8 = if (posix.getenv("ZMX_DIR")) |zmxdir|
            try alloc.dupe(u8, zmxdir)
        else if (posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime|
            try std.fmt.allocPrint(alloc, "{s}/zmx", .{xdg_runtime})
        else
            try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });
        errdefer alloc.free(socket_dir);

        return socket_dir;
    }

    pub fn deinit(self: *Cfg, alloc: std.mem.Allocator) void {
        if (self.socket_dir.len > 0) alloc.free(self.socket_dir);
        if (self.log_dir.len > 0) alloc.free(self.log_dir);
    }

    pub fn mkdir(self: *Cfg) !void {
        posix.mkdirat(posix.AT.FDCWD, self.socket_dir, 0o750) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        posix.mkdirat(posix.AT.FDCWD, self.log_dir, 0o750) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
};

const EnsureSessionResult = struct {
    created: bool,
    is_daemon: bool,
};

/// Daemon is responsible for managing a zmx session.
///
/// It holds all the state for a running session.  Instead of a single daemon for all sessions, we
/// create a daemon for every session.  This has some benefits. The ipc communication between
/// session clients and the daemon doesn't need to be tagged with the session name.  If a daemon
/// crashes for one session won't crash all the other sessions.
///
/// Conceptually it's also much simpler to reason about.
const Daemon = struct {
    cfg: *Cfg,
    alloc: std.mem.Allocator,
    clients: std.ArrayList(*Client),
    session_name: []const u8,
    socket_path: []const u8,
    running: bool,
    pid: i32,
    command: ?[]const []const u8 = null,
    cwd: []const u8 = "",
    has_pty_output: bool = false,
    has_had_client: bool = false,
    created_at: u64, // unix timestamp (ns)
    is_task_mode: bool = false, // flag for when session is run as a task
    task_exit_code: ?u8 = null, // null = running or n/a, set when task completes
    task_ended_at: ?u64 = null, // timestamp when task exited
    task_command: ?[]const []const u8 = null,

    pub fn deinit(self: *Daemon) void {
        self.clients.deinit(self.alloc);
        self.alloc.free(self.socket_path);
    }

    pub fn shutdown(self: *Daemon) void {
        std.log.info("shutting down daemon session_name={s}", .{self.session_name});
        self.running = false;

        for (self.clients.items) |client| {
            client.deinit();
            self.alloc.destroy(client);
        }
        self.clients.clearRetainingCapacity();
    }

    pub fn closeClient(self: *Daemon, client: *Client, i: usize, shutdown_on_last: bool) bool {
        const fd = client.socket_fd;
        client.deinit();
        self.alloc.destroy(client);
        _ = self.clients.orderedRemove(i);
        std.log.info("client disconnected fd={d} remaining={d}", .{ fd, self.clients.items.len });
        if (shutdown_on_last and self.clients.items.len == 0) {
            self.shutdown();
            return true;
        }
        return false;
    }

    /// Runs in the forked child. Either execs or returns an error (caller
    /// must exit on error -- returning would fall through to parent code).
    fn execChild(self: *Daemon) !noreturn {
        const alloc = std.heap.c_allocator;

        // main() set SIGPIPE to SIG_IGN, which (unlike handlers) survives
        // exec. Restore the default so the shell and its children behave
        // normally (e.g. `yes | head` should exit 141 via SIGPIPE).
        const dfl: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.PIPE, &dfl, null);

        const session_env = try std.fmt.allocPrintSentinel(
            alloc,
            "ZMX_SESSION={s}",
            .{self.session_name},
            0,
        );
        _ = cross.c.putenv(session_env.ptr);

        if (self.command) |cmd_args| {
            const argv = try alloc.allocSentinel(?[*:0]const u8, cmd_args.len, null);
            for (cmd_args, 0..) |arg, i| {
                argv[i] = try alloc.dupeZ(u8, arg);
            }
            const err = std.posix.execvpeZ(argv[0].?, argv.ptr, std.c.environ);
            std.log.err("execvpe failed: cmd={s} err={s}", .{ cmd_args[0], @errorName(err) });
            std.posix.exit(1);
        }

        const shell = util.detectShell();
        // Use "-shellname" as argv[0] to signal login shell (traditional method)
        const login_shell = try std.fmt.allocPrintSentinel(
            alloc,
            "-{s}",
            .{std.fs.path.basename(shell)},
            0,
        );
        const argv = [_:null]?[*:0]const u8{ login_shell, null };
        const err = std.posix.execveZ(shell, &argv, std.c.environ);
        std.log.err("execve failed: err={s}", .{@errorName(err)});
        std.posix.exit(1);
    }

    /// spawnPty runs forkpty() and executes the shell or shell command the user provides.
    fn spawnPty(self: *Daemon) !c_int {
        const size = ipc.getTerminalSize(posix.STDOUT_FILENO);
        var ws: cross.c.struct_winsize = .{
            .ws_row = size.rows,
            .ws_col = size.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var master_fd: c_int = undefined;
        const pid = cross.forkpty(&master_fd, null, null, &ws);
        if (pid < 0) {
            return error.ForkPtyFailed;
        }

        if (pid == 0) { // child pid code path
            // In the forked child, ANY error must exit rather than propagate:
            // a returned error falls through to the parent code path below,
            // running a second daemon on the same socket (or worse, hitting
            // errdefers that delete the parent's socket file).
            execChild(self) catch |err| {
                std.log.err("child setup failed: {s}", .{@errorName(err)});
                std.posix.exit(1);
            };
            unreachable; // execChild either execs or exits, never returns ok
        }
        // master pid code path
        self.pid = pid;
        std.log.info("pty spawned session={s} pid={d}", .{ self.session_name, pid });

        // make pty non-blocking
        const flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(master_fd, posix.F.SETFL, flags | O_NONBLOCK);
        return master_fd;
    }

    /// ensureSession "upserts" a session by checking if the unix socket exists already.
    /// If not it creates one and spawns the daemon.
    fn ensureSession(self: *Daemon) !EnsureSessionResult {
        var dir = try std.fs.openDirAbsolute(self.cfg.socket_dir, .{});
        defer dir.close();

        const exists = try socket.sessionExists(dir, self.session_name);
        var should_create = !exists;

        if (exists) {
            if (ipc.probeSession(self.alloc, self.socket_path)) |result| {
                posix.close(result.fd);
                if (self.command != null) {
                    std.log.warn(
                        "session already exists, ignoring command session={s}",
                        .{self.session_name},
                    );
                }
            } else |err| switch (err) {
                // Daemon is definitively gone: safe to replace.
                error.ConnectionRefused => {
                    socket.cleanupStaleSocket(dir, self.session_name);
                    should_create = true;
                },
                // Probe didn't respond in time -- daemon may just be busy.
                // The probe is only to decide create-vs-attach; the session
                // exists, so proceed to attach rather than fail or orphan.
                else => {
                    std.log.warn(
                        "probe slow ({s}), proceeding to attach session={s}",
                        .{ @errorName(err), self.session_name },
                    );
                },
            }
        }

        if (should_create) {
            std.log.info("creating session={s}", .{self.session_name});
            const server_sock_fd = try socket.createSocket(self.socket_path);

            // creates the daemon
            const pid = try posix.fork();
            if (pid == 0) { // child (daemon)
                // becomes the session leader and detaches process from its controlling terminal
                _ = try posix.setsid();

                log_system.deinit();
                const session_log_name = try std.fmt.allocPrint(
                    self.alloc,
                    "{s}.log",
                    .{self.session_name},
                );
                defer self.alloc.free(session_log_name);
                const session_log_path = try std.fs.path.join(
                    self.alloc,
                    &.{ self.cfg.log_dir, session_log_name },
                );
                defer self.alloc.free(session_log_path);
                try log_system.init(self.alloc, session_log_path);

                // Close file descriptors inherited from the parent that the
                // daemon doesn't need. This prevents test harnesses (like
                // bats) from hanging — they wait for their internal FDs (3+)
                // to close before exiting. We close FDs 3..server_sock_fd
                // (the parent's log FD lived here, now safely deinited) and
                // anything above server_sock_fd up to a reasonable limit.
                {
                    var fd: i32 = 3;
                    while (fd < server_sock_fd) : (fd += 1) {
                        _ = std.c.close(fd);
                    }
                    fd = server_sock_fd + 1;
                    while (fd < 64) : (fd += 1) {
                        _ = std.c.close(fd);
                    }
                }

                // If spawnPty fails, clean up here. Once it succeeds,
                // the inner block's defer takes ownership of cleanup to
                // avoid double-closing server_sock_fd on daemonLoop error.
                const pty_fd = self.spawnPty() catch |err| {
                    posix.close(server_sock_fd);
                    dir.deleteFile(self.session_name) catch {};
                    return err;
                };

                defer {
                    self.handleKill();
                    self.deinit();
                    _ = posix.waitpid(self.pid, 0);
                    posix.close(pty_fd);
                    posix.close(server_sock_fd);
                    std.log.info("deleting socket file session_name={s}", .{self.session_name});
                    dir.deleteFile(self.session_name) catch |err| {
                        std.log.warn("failed to delete socket file err={s}", .{@errorName(err)});
                    };
                }

                try daemonLoop(self, server_sock_fd, pty_fd);
                return .{ .created = true, .is_daemon = true };
            }
            posix.close(server_sock_fd);
            std.Thread.sleep(10 * std.time.ns_per_ms);
            return .{ .created = true, .is_daemon = false };
        }

        return .{ .created = false, .is_daemon = false };
    }

    /// Best-effort write to the (non-blocking) PTY fd. Retries short writes
    /// until complete, but on WouldBlock (kernel buffer full) gives up and
    /// drops the remainder — the daemon is single-threaded, so blocking here
    /// to wait for POLLOUT would deadlock against a shell that's itself
    /// blocked writing echo to a full PTY output buffer that we're not
    /// draining. Dropping is the same trade-off the old code made implicitly
    /// (short writes were silently truncated), just without the crash.
    fn ptyWrite(pty_fd: i32, data: []const u8) void {
        var remaining = data;
        while (remaining.len > 0) {
            const n = posix.write(pty_fd, remaining) catch |err| {
                if (err == error.WouldBlock) {
                    std.log.warn(
                        "pty write dropped {d}/{d} bytes (buffer full)",
                        .{ remaining.len, data.len },
                    );
                } else {
                    std.log.warn(
                        "pty write failed, {d} bytes lost: {s}",
                        .{ remaining.len, @errorName(err) },
                    );
                }
                return;
            };
            if (n == 0) return;
            remaining = remaining[n..];
        }
    }

    pub fn handleInput(self: *Daemon, pty_fd: i32, payload: []const u8) void {
        _ = self;
        if (payload.len > 0) {
            ptyWrite(pty_fd, payload);
        }
    }

    pub fn handleInit(
        self: *Daemon,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);

        // Serialize terminal state BEFORE resize to capture correct cursor position.
        // Resizing triggers reflow which can move the cursor, and the shell's
        // SIGWINCH-triggered redraw will run after our snapshot is sent.
        // Only serialize on re-attach (has_had_client), not first attach, to avoid
        // interfering with shell initialization (DA1 queries, etc.)
        if (self.has_pty_output and self.has_had_client) {
            const cursor = &term.screens.active.cursor;
            std.log.debug(
                "cursor before serialize: x={d} y={d} pending_wrap={}",
                .{ cursor.x, cursor.y, cursor.pending_wrap },
            );
            if (util.serializeTerminalState(self.alloc, term)) |term_output| {
                std.log.debug("serialize terminal state", .{});
                defer self.alloc.free(term_output);
                ipc.appendMessage(self.alloc, &client.write_buf, .Output, term_output) catch |err| {
                    std.log.warn(
                        "failed to buffer terminal state for client err={s}",
                        .{@errorName(err)},
                    );
                };
                client.has_pending_output = true;
            }
        }

        var ws: cross.c.struct_winsize = .{
            .ws_row = resize.rows,
            .ws_col = resize.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = cross.c.ioctl(pty_fd, cross.c.TIOCSWINSZ, &ws);
        try term.resize(self.alloc, resize.cols, resize.rows);

        // Mark that we've had a client init, so subsequent clients get terminal state
        self.has_had_client = true;

        std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleResize(
        self: *Daemon,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        var ws: cross.c.struct_winsize = .{
            .ws_row = resize.rows,
            .ws_col = resize.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = cross.c.ioctl(pty_fd, cross.c.TIOCSWINSZ, &ws);
        try term.resize(self.alloc, resize.cols, resize.rows);
        std.log.debug("resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleDetach(self: *Daemon, client: *Client, i: usize) void {
        std.log.info("client detach fd={d}", .{client.socket_fd});
        _ = self.closeClient(client, i, false);
    }

    pub fn handleDetachAll(self: *Daemon) void {
        std.log.info("detach all clients={d}", .{self.clients.items.len});
        for (self.clients.items) |client_to_close| {
            client_to_close.deinit();
            self.alloc.destroy(client_to_close);
        }
        self.clients.clearRetainingCapacity();
    }

    pub fn handleKill(self: *Daemon) void {
        std.log.info("kill received session={s}", .{self.session_name});
        self.shutdown();
        // gracefully shutdown shell processes, shells tend to ignore SIGTERM so we send SIGHUP
        // instead
        //   https://www.gnu.org/software/bash/manual/html_node/Signals.html
        // negative pid means kill process and children
        std.log.info("sending SIGHUP session={s} pid={d}", .{ self.session_name, self.pid });
        posix.kill(-self.pid, posix.SIG.HUP) catch |err| {
            std.log.warn("failed to send SIGHUP to pty child err={s}", .{@errorName(err)});
        };
        std.Thread.sleep(500 * std.time.ns_per_ms);
        posix.kill(-self.pid, posix.SIG.KILL) catch |err| {
            std.log.warn("failed to send SIGKILL to pty child err={s}", .{@errorName(err)});
        };
    }

    pub fn handleInfo(self: *Daemon, client: *Client) !void {
        const clients_len = self.clients.items.len - 1;

        // Build command string from args, re-quoting args that contain
        // shell-special characters so the displayed command is copy-pasteable.
        var cmd_buf: [ipc.MAX_CMD_LEN]u8 = undefined;
        var cmd_len: u16 = 0;
        const cur_cmd = self.command orelse self.task_command;
        if (cur_cmd) |args| {
            for (args, 0..) |arg, i| {
                const quoted = if (util.shellNeedsQuoting(arg))
                    util.shellQuote(self.alloc, arg) catch null
                else
                    null;
                defer if (quoted) |q| self.alloc.free(q);
                const src = quoted orelse arg;

                const need = src.len + @as(usize, if (i > 0) 1 else 0);
                if (cmd_len + need > ipc.MAX_CMD_LEN) {
                    const ellipsis = "...";
                    if (cmd_len + ellipsis.len <= ipc.MAX_CMD_LEN) {
                        @memcpy(cmd_buf[cmd_len..][0..ellipsis.len], ellipsis);
                        cmd_len += ellipsis.len;
                    }
                    break;
                }

                if (i > 0) {
                    cmd_buf[cmd_len] = ' ';
                    cmd_len += 1;
                }
                @memcpy(cmd_buf[cmd_len..][0..src.len], src);
                cmd_len += @intCast(src.len);
            }
        }

        // Copy cwd
        var cwd_buf: [ipc.MAX_CWD_LEN]u8 = undefined;
        const cwd_len: u16 = @intCast(@min(self.cwd.len, ipc.MAX_CWD_LEN));
        @memcpy(cwd_buf[0..cwd_len], self.cwd[0..cwd_len]);

        const info = ipc.Info{
            .clients_len = clients_len,
            .pid = self.pid,
            .cmd_len = cmd_len,
            .cwd_len = cwd_len,
            .cmd = cmd_buf,
            .cwd = cwd_buf,
            .created_at = self.created_at,
            .task_ended_at = self.task_ended_at orelse 0,
            .task_exit_code = self.task_exit_code orelse 0,
        };
        try ipc.appendMessage(self.alloc, &client.write_buf, .Info, std.mem.asBytes(&info));
        client.has_pending_output = true;
    }

    pub fn handleHistory(
        self: *Daemon,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        const format: util.HistoryFormat = if (payload.len > 0)
            std.meta.intToEnum(util.HistoryFormat, payload[0]) catch .plain
        else
            .plain;
        if (util.serializeTerminal(self.alloc, term, format)) |output| {
            defer self.alloc.free(output);
            try ipc.appendMessage(self.alloc, &client.write_buf, .History, output);
            client.has_pending_output = true;
        } else {
            try ipc.appendMessage(self.alloc, &client.write_buf, .History, "");
            client.has_pending_output = true;
        }
    }

    pub fn handleRun(self: *Daemon, client: *Client, pty_fd: i32, payload: []const u8) !void {
        // Reset task tracking so the new command's exit marker is detected.
        // Without this, a second `zmx run` on the same session is ignored
        // because task_exit_code is still set from the first run.
        self.task_exit_code = null;
        self.task_ended_at = null;
        self.is_task_mode = true;

        if (payload.len > 0) {
            ptyWrite(pty_fd, payload);
        }
        try ipc.appendMessage(self.alloc, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        self.has_had_client = true;
        std.log.debug("run command len={d}", .{payload.len});
    }
};

fn printVersion(cfg: *Cfg) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    var ver = version;
    if (builtin.mode == .Debug) {
        ver = git_sha;
    }
    try w.interface.print(
        "zmx\t\t{s}\nghostty_vt\t{s}\nsocket_dir\t{s}\nlog_dir\t\t{s}\n",
        .{ ver, ghostty_version, cfg.socket_dir, cfg.log_dir },
    );
    try w.interface.flush();
}

fn printCompletions(shell: completions.Shell) !void {
    const script = shell.getCompletionScript();
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("{s}\n", .{script});
    try w.interface.flush();
}

fn help() !void {
    const help_text =
        \\zmx - session persistence for terminal processes
        \\
        \\Usage: zmx <command> [args]
        \\
        \\Commands:
        \\  [a]ttach <name> [command...]   Attach to session, creating session if needed
        \\  [r]un <name> [command...]      Send command without attaching, creating session if needed
        \\  [d]etach                       Detach all clients from current session (ctrl+\ for current client)
        \\  [l]ist [--short]               List active sessions
        \\  [k]ill <name>...               Kill a session and all attached clients
        \\  [hi]story <name> [--vt|--html] Output session scrollback (--vt or --html for escape sequences)
        \\  [w]ait <name>...               Wait for session tasks to complete
        \\  [c]ompletions <shell>          Completion scripts for shell integration (bash, zsh, or fish)
        \\  [v]ersion                      Show version information
        \\  [h]elp                         Show this help message
        \\
        \\Environment variables:
        \\  - SHELL                Determines which shell is used when creating a session
        \\  - ZMX_DIR              Controls which folder is used to store unix socket files (prio: 1)
        \\  - XDG_RUNTIME_DIR      Controls which folder is used to store unix socket files (prio: 2)
        \\  - TMPDIR               Controls which folder is used to store unix socket files (prio: 3)
        \\  - ZMX_SESSION          The session name we inject into every zmx session automatically
        \\  - ZMX_SESSION_PREFIX   Adds this value to the start of every session name for all commands
        \\
    ;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(help_text, .{});
    try w.interface.flush();
}

fn wait(cfg: *Cfg, session_names: std.ArrayList([]const u8)) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Highest match count seen so far. Lets us distinguish "sessions haven't
    // appeared yet" (keep polling) from "sessions we were tracking
    // disappeared" (fail -- daemon crashed or was killed).
    var max_seen: i32 = 0;
    var zero_match_iters: u32 = 0;

    while (true) {
        var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
        var total: i32 = 0;
        var done: i32 = 0;
        var agg_exit_code: u8 = 0;

        for (sessions.items) |session| {
            var found = false;
            for (session_names.items) |prefix| {
                if (std.mem.startsWith(u8, session.name, prefix)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                continue;
            }

            total += 1;
            if (session.is_error) {
                // Daemon unreachable (probe timed out). On Timeout the socket
                // is no longer deleted, so this session would otherwise
                // persist as task_ended_at==0 forever → infinite "still
                // waiting". Count it as done+failed so wait terminates.
                try stderr.print(
                    "task unreachable: {s} ({s})\n",
                    .{ session.name, session.error_name orelse "unknown" },
                );
                try stderr.flush();
                agg_exit_code = 1;
                done += 1;
                continue;
            }
            if (session.task_ended_at == 0) {
                try stdout.print("waiting task={s}\n", .{session.name});
                try stdout.flush();
                continue;
            }
            try stdout.print("completed task={s} exit_code={d}\n", .{ session.name, session.task_exit_code.? });
            try stdout.flush();
            if (session.task_exit_code != 0) {
                agg_exit_code = session.task_exit_code orelse 0;
            }
            done += 1;
        }

        for (sessions.items) |session| {
            session.deinit(alloc);
        }
        sessions.deinit(alloc);

        // Check disappearance BEFORE completion: if one of N sessions
        // crashed and the remaining N-1 happen to be done, total==done
        // would be a false success.
        if (total < max_seen) {
            try stderr.print(
                "error: {d} session(s) disappeared before completing\n",
                .{max_seen - total},
            );
            try stderr.flush();
            std.process.exit(1);
            return;
        }
        max_seen = total;

        if (total > 0 and total == done) {
            if (agg_exit_code == 0) {
                try stdout.print("task(s) completed!\n", .{});
            } else {
                try stdout.print("task(s) failed!\n", .{});
            }
            try stdout.flush();
            std.process.exit(agg_exit_code);
            return;
        }

        if (max_seen == 0) {
            // `zmx run foo && zmx wait foo` is essentially sequential, so
            // matching sessions should be visible from the first poll. If
            // nothing appears after a few iterations it's almost certainly a
            // typo, not a slow start.
            zero_match_iters += 1;
            if (zero_match_iters >= 3) {
                try stderr.print("error: no matching sessions found\n", .{});
                try stderr.flush();
                std.process.exit(2);
                return;
            }
        }

        std.Thread.sleep(3000 * std.time.ns_per_ms);
    }
}

fn list(cfg: *Cfg, short: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const current_session = std.process.getEnvVarOwned(alloc, "ZMX_SESSION") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (current_session) |name| alloc.free(name);
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
    defer {
        for (sessions.items) |session| {
            session.deinit(alloc);
        }
        sessions.deinit(alloc);
    }

    if (sessions.items.len == 0) {
        if (short) return;
        var errbuf: [4096]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&errbuf);
        try stderr.interface.print("no sessions found in {s}\n", .{cfg.socket_dir});
        try stderr.interface.flush();
        return;
    }

    std.mem.sort(util.SessionEntry, sessions.items, {}, util.SessionEntry.lessThan);

    for (sessions.items) |session| {
        try util.writeSessionLine(&stdout.interface, session, short, current_session);
        try stdout.interface.flush();
    }
}

fn detachAll(cfg: *Cfg) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const session_name = std.process.getEnvVarOwned(alloc, "ZMX_SESSION") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.log.err("ZMX_SESSION env var not found: are you inside a zmx session?", .{});
            return;
        },
        else => return err,
    };
    defer alloc.free(session_name);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);
    const result = ipc.probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return;
    };
    defer posix.close(result.fd);
    ipc.send(result.fd, .DetachAll, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

fn kill(cfg: *Cfg, session_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, session_name);
    if (!exists) {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        w.interface.print("error: session \"{s}\" does not exist\n", .{session_name}) catch {};
        w.interface.flush() catch {};
        return error.SessionNotFound;
    }
    const result = ipc.probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        if (err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(dir, session_name);
            w.interface.print("cleaned up stale session {s}\n", .{session_name}) catch {};
        } else {
            w.interface.print(
                "session {s} is unresponsive ({s}) -- daemon may be busy, try again or kill the process directly\n",
                .{ session_name, @errorName(err) },
            ) catch {};
        }
        w.interface.flush() catch {};
        return;
    };

    defer posix.close(result.fd);
    ipc.send(result.fd, .Kill, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var buf: [100]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("killed session {s}\n", .{session_name});
    try w.interface.flush();
}

fn history(cfg: *Cfg, session_name: []const u8, format: util.HistoryFormat) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, session_name);
    if (!exists) {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        w.interface.print("error: session \"{s}\" does not exist\n", .{session_name}) catch {};
        w.interface.flush() catch {};
        return error.SessionNotFound;
    }
    const result = ipc.probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return;
    };
    defer posix.close(result.fd);

    const format_byte = [_]u8{@intFromEnum(format)};
    ipc.send(result.fd, .History, &format_byte) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    while (true) {
        var poll_fds = [_]posix.pollfd{.{ .fd = result.fd, .events = posix.POLL.IN, .revents = 0 }};
        const poll_result = posix.poll(&poll_fds, 5000) catch return;
        if (poll_result == 0) {
            std.log.err("timeout waiting for history response", .{});
            return;
        }

        const n = sb.read(result.fd) catch return;
        if (n == 0) return;

        while (sb.next()) |msg| {
            if (msg.header.tag == .History) {
                _ = posix.write(posix.STDOUT_FILENO, msg.payload) catch return;
                return;
            }
        }
    }
}

fn attach(daemon: *Daemon) !void {
    const sesh = socket.getSeshNameFromEnv();
    if (sesh.len > 0) {
        return error.CannotAttachToSessionInSession;
    }

    const result = try daemon.ensureSession();
    if (result.is_daemon) return;

    const client_sock = try socket.sessionConnect(daemon.socket_path);
    std.log.info("attached session={s}", .{daemon.session_name});
    //  This is typically used with tcsetattr() to modify terminal settings.
    //      - you first get the current settings with tcgetattr()
    //      - modify the desired attributes in the termios structure
    //      - then apply the changes with tcsetattr().
    //  This prevents unintended side effects by preserving other settings.
    // restore stdin fd to its original state after exiting.
    // Use TCSAFLUSH to discard any unread input, preventing stale input after detach.
    //
    // tcgetattr fails when stdin is not a TTY (e.g. piped). In that case,
    // skip terminal setup entirely rather than applying undefined stack bytes
    // via tcsetattr.
    var orig_termios: cross.c.termios = undefined;
    const stdin_is_tty = cross.c.tcgetattr(posix.STDIN_FILENO, &orig_termios) == 0;

    defer {
        if (stdin_is_tty) {
            _ = cross.c.tcsetattr(posix.STDIN_FILENO, cross.c.TCSAFLUSH, &orig_termios);
        }
        // Reset terminal modes on detach:
        // - Mouse: 1000=basic, 1002=button-event, 1003=any-event, 1006=SGR extended
        // - 2004=bracketed paste, 1004=focus events, 1049=alt screen
        // - 25h=show cursor
        // NOTE: We intentionally do NOT clear screen or home cursor here because we dont
        // want to corrupt any programs that rely on it including ghostty's session restore.
        const restore_seq = "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l" ++
            "\x1b[?2004l\x1b[?1004l\x1b[?1049l" ++
            // Restore pre-attach Kitty keyboard protocol mode so Ctrl combos
            // return to legacy encoding in the user's outer shell.
            "\x1b[<u" ++
            "\x1b[?25h";
        _ = posix.write(posix.STDOUT_FILENO, restore_seq) catch {};
    }

    if (stdin_is_tty) {
        var raw_termios = orig_termios;
        //  set raw mode after successful connection.
        //      disables canonical mode (line buffering), input echoing, signal generation from
        //      control characters (like Ctrl+C), and flow control.
        cross.c.cfmakeraw(&raw_termios);

        // Additional granular raw mode settings for precise control
        // (matches what abduco and shpool do)
        raw_termios.c_cc[cross.c.VLNEXT] = cross.c._POSIX_VDISABLE; // Disable literal-next (Ctrl-V)
        // We want to intercept Ctrl+\ (SIGQUIT) so we can use it as a detach key
        raw_termios.c_cc[cross.c.VQUIT] = cross.c._POSIX_VDISABLE; // Disable SIGQUIT (Ctrl+\)
        raw_termios.c_cc[cross.c.VMIN] = 1; // Minimum chars to read: return after 1 byte
        raw_termios.c_cc[cross.c.VTIME] = 0; // Read timeout: no timeout, return immediately

        _ = cross.c.tcsetattr(posix.STDIN_FILENO, cross.c.TCSANOW, &raw_termios);
    }

    // Clear screen before attaching. This provides a clean slate before
    // the session restore.
    const clear_seq = "\x1b[2J\x1b[H";
    _ = try posix.write(posix.STDOUT_FILENO, clear_seq);

    try clientLoop(client_sock);
}

fn run(daemon: *Daemon, command_args: [][]const u8) !void {
    const alloc = daemon.alloc;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);

    var cmd_to_send: ?[]const u8 = null;
    var allocated_cmd: ?[]u8 = null;
    defer if (allocated_cmd) |cmd| alloc.free(cmd);

    const result = try daemon.ensureSession();
    if (result.is_daemon) return;

    if (result.created) {
        try w.interface.print("session \"{s}\" created\n", .{daemon.session_name});
        try w.interface.flush();
    }

    const shell = util.detectShell();
    const shell_basename = std.fs.path.basename(shell);
    // We append a task marker so we can:
    //   - know when the command finishes
    //   - capture its exit status
    // This information is retrived when running `zmx list`
    const inline_task_marker = if (std.mem.eql(u8, shell_basename, "fish"))
        "; echo ZMX_TASK_COMPLETED:$status"
    else
        "; echo ZMX_TASK_COMPLETED:$?";
    const stdin_task_marker = if (std.mem.eql(u8, shell_basename, "fish"))
        "echo ZMX_TASK_COMPLETED:$status"
    else
        "echo ZMX_TASK_COMPLETED:$?";

    if (command_args.len > 0) {
        var cmd_list = std.ArrayList(u8).empty;
        defer cmd_list.deinit(alloc);

        for (command_args, 0..) |arg, i| {
            if (i > 0) try cmd_list.append(alloc, ' ');
            if (util.shellNeedsQuoting(arg)) {
                const quoted = try util.shellQuote(alloc, arg);
                defer alloc.free(quoted);
                try cmd_list.appendSlice(alloc, quoted);
            } else {
                try cmd_list.appendSlice(alloc, arg);
            }
        }

        try cmd_list.appendSlice(alloc, inline_task_marker);
        // \r, not \n: once the shell is at the readline prompt the PTY is in
        // raw mode; readline's accept-line binds to CR. The first-ever run
        // works with \n only because it arrives during shell startup while
        // the line discipline is still canonical.
        try cmd_list.append(alloc, '\r');

        cmd_to_send = try cmd_list.toOwnedSlice(alloc);
        allocated_cmd = @constCast(cmd_to_send.?);
    } else {
        const stdin_fd = posix.STDIN_FILENO;
        if (!std.posix.isatty(stdin_fd)) {
            var stdin_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
            defer stdin_buf.deinit(alloc);

            while (true) {
                var tmp: [4096]u8 = undefined;
                const n = posix.read(stdin_fd, &tmp) catch |err| {
                    if (err == error.WouldBlock) break;
                    return err;
                };
                if (n == 0) break;
                try stdin_buf.appendSlice(alloc, tmp[0..n]);
            }

            if (stdin_buf.items.len > 0) {
                // Normalize any trailing newline to CR so readline (raw mode)
                // accepts each line.
                if (stdin_buf.items[stdin_buf.items.len - 1] == '\n') {
                    stdin_buf.items[stdin_buf.items.len - 1] = '\r';
                } else {
                    try stdin_buf.append(alloc, '\r');
                }

                try stdin_buf.appendSlice(alloc, stdin_task_marker);
                try stdin_buf.append(alloc, '\r');

                cmd_to_send = try alloc.dupe(u8, stdin_buf.items);
                allocated_cmd = @constCast(cmd_to_send.?);
            }
        }
    }

    if (cmd_to_send == null) {
        return error.CommandRequired;
    }

    const probe_result = ipc.probeSession(alloc, daemon.socket_path) catch |err| {
        std.log.err("session not ready: {s}", .{@errorName(err)});
        return error.SessionNotReady;
    };
    defer posix.close(probe_result.fd);

    ipc.send(probe_result.fd, .Run, cmd_to_send.?) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };

    var poll_fds = [_]posix.pollfd{
        .{ .fd = probe_result.fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const poll_result = posix.poll(&poll_fds, 5000) catch return error.PollFailed;
    if (poll_result == 0) {
        std.log.err("timeout waiting for ack", .{});
        return error.Timeout;
    }

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    const n = sb.read(probe_result.fd) catch return error.ReadFailed;
    if (n == 0) return error.ConnectionClosed;

    while (sb.next()) |msg| {
        if (msg.header.tag == .Ack) {
            try w.interface.print("command sent\n", .{});
            try w.interface.flush();
            return;
        }
    }

    return error.NoAckReceived;
}

/// clientLoop sends ipc commands to its corresponding daemon.  It uses poll() as its non-blocking
/// mechanism. It will send stdin to the daemon and receive stdout from the daemon.
fn clientLoop(client_sock_fd: i32) !void {
    // use c_allocator to avoid "reached unreachable code" panic in DebugAllocator when forking
    const alloc = std.heap.c_allocator;
    defer posix.close(client_sock_fd);

    setupSigwinchHandler();

    // Make socket non-blocking to avoid blocking on writes
    var sock_flags = try posix.fcntl(client_sock_fd, posix.F.GETFL, 0);
    sock_flags |= O_NONBLOCK;
    _ = try posix.fcntl(client_sock_fd, posix.F.SETFL, sock_flags);

    // Buffer for outgoing socket writes
    var sock_write_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer sock_write_buf.deinit(alloc);

    // Send init message with terminal size (buffered)
    const size = ipc.getTerminalSize(posix.STDOUT_FILENO);
    try ipc.appendMessage(alloc, &sock_write_buf, .Init, std.mem.asBytes(&size));

    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(alloc, 4);
    defer poll_fds.deinit(alloc);

    var read_buf = try ipc.SocketBuffer.init(alloc);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer stdout_buf.deinit(alloc);

    const stdin_fd = posix.STDIN_FILENO;

    // Make stdin non-blocking. O_NONBLOCK is set on the open file description,
    // which is shared with the parent shell; restore on exit to avoid
    // corrupting the parent's stdin.
    const stdin_orig_flags = try posix.fcntl(stdin_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(stdin_fd, posix.F.SETFL, stdin_orig_flags | O_NONBLOCK);
    defer _ = posix.fcntl(stdin_fd, posix.F.SETFL, stdin_orig_flags) catch {};

    while (true) {
        // Check for pending SIGWINCH
        if (sigwinch_received.swap(false, .acq_rel)) {
            const next_size = ipc.getTerminalSize(posix.STDOUT_FILENO);
            try ipc.appendMessage(alloc, &sock_write_buf, .Resize, std.mem.asBytes(&next_size));
        }

        poll_fds.clearRetainingCapacity();

        try poll_fds.append(alloc, .{
            .fd = stdin_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        });

        // Poll socket for read, and also for write if we have pending data
        var sock_events: i16 = posix.POLL.IN;
        if (sock_write_buf.items.len > 0) {
            sock_events |= posix.POLL.OUT;
        }
        try poll_fds.append(alloc, .{
            .fd = client_sock_fd,
            .events = sock_events,
            .revents = 0,
        });

        if (stdout_buf.items.len > 0) {
            try poll_fds.append(alloc, .{
                .fd = posix.STDOUT_FILENO,
                .events = posix.POLL.OUT,
                .revents = 0,
            });
        }

        _ = posix.poll(poll_fds.items, -1) catch |err| {
            if (err == error.Interrupted) continue; // EINTR from signal, loop again
            return err;
        };

        // Handle stdin -> socket (Input)
        const inp_flags = (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL);
        if (poll_fds.items[0].revents & inp_flags != 0) {
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = posix.read(stdin_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                return err;
            };

            if (n_opt) |n| {
                if (n > 0) {
                    // Check for detach sequences (ctrl+\ as first byte or Kitty escape sequence)
                    if (buf[0] == 0x1C or util.isKittyCtrlBackslash(buf[0..n])) {
                        try ipc.appendMessage(alloc, &sock_write_buf, .Detach, "");
                    } else {
                        try ipc.appendMessage(alloc, &sock_write_buf, .Input, buf[0..n]);
                    }
                } else {
                    // EOF on stdin
                    return;
                }
            }
        }

        // Handle socket read (incoming Output messages from daemon)
        if (poll_fds.items[1].revents & posix.POLL.IN != 0) {
            const n = read_buf.read(client_sock_fd) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    return;
                }
                std.log.err("daemon read err={s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) {
                return; // Server closed connection
            }

            while (read_buf.next()) |msg| {
                switch (msg.header.tag) {
                    .Output => {
                        if (msg.payload.len > 0) {
                            try stdout_buf.appendSlice(alloc, msg.payload);
                        }
                    },
                    else => {},
                }
            }
        }

        // Handle socket write (flush buffered messages to daemon)
        if (poll_fds.items[1].revents & posix.POLL.OUT != 0) {
            if (sock_write_buf.items.len > 0) {
                const n = posix.write(client_sock_fd, sock_write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                        return;
                    }
                    return err;
                };
                if (n > 0) {
                    try sock_write_buf.replaceRange(alloc, 0, n, &[_]u8{});
                }
            }
        }

        if (stdout_buf.items.len > 0) {
            const n = posix.write(posix.STDOUT_FILENO, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (n > 0) {
                try stdout_buf.replaceRange(alloc, 0, n, &[_]u8{});
            }
        }

        if (poll_fds.items[1].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
            return;
        }
    }
}

/// dameonLoop is what the daemon runs to send and receive ipc commands from its corresponding
/// clients.  It uses poll() as its non-blocking mechanism.
fn daemonLoop(daemon: *Daemon, server_sock_fd: i32, pty_fd: i32) !void {
    std.log.info("daemon started session={s} pty_fd={d}", .{ daemon.session_name, pty_fd });
    setupSigtermHandler();
    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(daemon.alloc, 8);
    defer poll_fds.deinit(daemon.alloc);

    const init_size = ipc.getTerminalSize(pty_fd);
    var term = try ghostty_vt.Terminal.init(daemon.alloc, .{
        .cols = init_size.cols,
        .rows = init_size.rows,
        .max_scrollback = daemon.cfg.max_scrollback,
    });
    defer term.deinit(daemon.alloc);
    var vt_stream = term.vtStream();
    defer vt_stream.deinit();

    daemon_loop: while (daemon.running) {
        if (sigterm_received.swap(false, .acq_rel)) {
            std.log.info(
                "SIGTERM received, shutting down gracefully session={s}",
                .{daemon.session_name},
            );
            break :daemon_loop;
        }

        poll_fds.clearRetainingCapacity();

        try poll_fds.append(daemon.alloc, .{
            .fd = server_sock_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        });

        try poll_fds.append(daemon.alloc, .{
            .fd = pty_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        });

        for (daemon.clients.items) |client| {
            var events: i16 = posix.POLL.IN;
            if (client.has_pending_output) {
                events |= posix.POLL.OUT;
            }
            try poll_fds.append(daemon.alloc, .{
                .fd = client.socket_fd,
                .events = events,
                .revents = 0,
            });
        }

        _ = posix.poll(poll_fds.items, -1) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };

        if (poll_fds.items[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            std.log.err("server socket error revents={d}", .{poll_fds.items[0].revents});
            break :daemon_loop;
        } else if (poll_fds.items[0].revents & posix.POLL.IN != 0) {
            const client_fd = try posix.accept(
                server_sock_fd,
                null,
                null,
                posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            );
            const client = try daemon.alloc.create(Client);
            client.* = Client{
                .alloc = daemon.alloc,
                .socket_fd = client_fd,
                .read_buf = try ipc.SocketBuffer.init(daemon.alloc),
                .write_buf = undefined,
            };
            client.write_buf = try std.ArrayList(u8).initCapacity(client.alloc, 4096);
            try daemon.clients.append(daemon.alloc, client);
            std.log.info(
                "client connected fd={d} total={d}",
                .{ client_fd, daemon.clients.items.len },
            );
        }

        const inp_flags = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;
        if (poll_fds.items[1].revents & inp_flags != 0) {
            // Read from PTY
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = posix.read(pty_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                break :blk 0;
            };

            if (n_opt) |n| {
                if (n == 0) {
                    // EOF: Shell exited
                    std.log.info("shell exited pty_fd={d}", .{pty_fd});
                    break :daemon_loop;
                } else {
                    // Feed PTY output to terminal emulator for state tracking
                    try vt_stream.nextSlice(buf[0..n]);
                    daemon.has_pty_output = true;

                    // When no clients are attached, respond to terminal
                    // queries (e.g. DA1/DA2) on behalf of the terminal.
                    // This prevents shells like from fish from waiting 2s
                    // and then sending a no DA query response warning because
                    // there's no client terminal to respond to the query.
                    if (daemon.clients.items.len == 0) {
                        util.respondToDeviceAttributes(pty_fd, buf[0..n]);
                    }

                    // In run mode, scan output for exit code marker
                    if (daemon.is_task_mode and daemon.task_exit_code == null) {
                        if (util.findTaskExitMarker(buf[0..n])) |exit_code| {
                            daemon.task_exit_code = exit_code;
                            daemon.task_ended_at = @intCast(std.time.timestamp());

                            std.log.info("task completed exit_code={d}", .{exit_code});
                            // Shell continues running - no break here
                        }
                    }

                    // Broadcast data to all clients
                    for (daemon.clients.items) |client| {
                        ipc.appendMessage(daemon.alloc, &client.write_buf, .Output, buf[0..n]) catch |err| {
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

        var i: usize = daemon.clients.items.len;
        // Only iterate over clients that were present when poll_fds was constructed
        // poll_fds contains [server, pty, client0, client1, ...]
        // So number of clients in poll_fds is poll_fds.items.len - 2
        const num_polled_clients = poll_fds.items.len - 2;
        if (i > num_polled_clients) {
            // If we have more clients than polled (i.e. we just accepted one), start from the
            // polled ones
            i = num_polled_clients;
        }

        clients_loop: while (i > 0) {
            i -= 1;
            const client = daemon.clients.items[i];
            const revents = poll_fds.items[i + 2].revents;

            if (revents & posix.POLL.IN != 0) {
                const n = client.read_buf.read(client.socket_fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    std.log.debug(
                        "client read err={s} fd={d}",
                        .{ @errorName(err), client.socket_fd },
                    );
                    const last = daemon.closeClient(client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n == 0) {
                    // Client closed connection
                    const last = daemon.closeClient(client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                }

                while (client.read_buf.next()) |msg| {
                    switch (msg.header.tag) {
                        .Input => daemon.handleInput(pty_fd, msg.payload),
                        .Init => try daemon.handleInit(client, pty_fd, &term, msg.payload),
                        .Resize => try daemon.handleResize(pty_fd, &term, msg.payload),
                        .Detach => {
                            daemon.handleDetach(client, i);
                            break :clients_loop;
                        },
                        .DetachAll => {
                            daemon.handleDetachAll();
                            break :clients_loop;
                        },
                        .Kill => {
                            break :daemon_loop;
                        },
                        .Info => try daemon.handleInfo(client),
                        .History => try daemon.handleHistory(client, &term, msg.payload),
                        .Run => try daemon.handleRun(client, pty_fd, msg.payload),
                        .Output, .Ack => {},
                        _ => std.log.warn(
                            "ignoring unknown IPC tag={d}",
                            .{@intFromEnum(msg.header.tag)},
                        ),
                    }
                }
            }

            if (revents & posix.POLL.OUT != 0) {
                // Flush pending output buffers
                const n = posix.write(client.socket_fd, client.write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    // Error on write, close client
                    const last = daemon.closeClient(client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n > 0) {
                    client.write_buf.replaceRange(daemon.alloc, 0, n, &[_]u8{}) catch unreachable;
                }

                if (client.write_buf.items.len == 0) {
                    client.has_pending_output = false;
                }
            }

            if (revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                const last = daemon.closeClient(client, i, false);
                if (last) break :daemon_loop;
            }
        }
    }
}

fn handleSigwinch(_: i32, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    sigwinch_received.store(true, .release);
}

fn handleSigterm(_: i32, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    sigterm_received.store(true, .release);
}

// No SA_RESTART: we want the signal to interrupt poll() so the
// loop can check the flag. On BSD/macOS, SA_RESTART makes poll restartable,
// which would leave an idle daemon deaf to SIGTERM until other I/O wakes it.
fn setupSigwinchHandler() void {
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO,
    };
    posix.sigaction(posix.SIG.WINCH, &act, null);
}

fn setupSigtermHandler() void {
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleSigterm },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
}

fn ignoreSigpipe() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);
}
