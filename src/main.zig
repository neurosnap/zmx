const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const build_options = @import("build_options");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const completions = @import("completions.zig");

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

const c = switch (builtin.os.tag) {
    .macos => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("termios.h");
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
    .freebsd => @cImport({
        @cInclude("termios.h"); // ioctl and constants
        @cInclude("libutil.h"); // openpty()
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
    else => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("pty.h");
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
};

// Manually declare forkpty for macOS since util.h is not available during cross-compilation
const forkpty = if (builtin.os.tag == .macos)
    struct {
        extern "c" fn forkpty(master_fd: *c_int, name: ?[*:0]u8, termp: ?*const c.struct_termios, winp: ?*const c.struct_winsize) c_int;
    }.forkpty
else
    c.forkpty;

var sigwinch_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var sigterm_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

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

const Cfg = struct {
    socket_dir: []const u8,
    log_dir: []const u8,
    max_scrollback: usize = 10_000_000,

    pub fn init(alloc: std.mem.Allocator) !Cfg {
        const tmpdir = std.mem.trimRight(u8, posix.getenv("TMPDIR") orelse "/tmp", "/");
        const uid = posix.getuid();

        const socket_dir: []const u8 = if (posix.getenv("ZMX_DIR")) |zmxdir|
            try alloc.dupe(u8, zmxdir)
        else if (posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime|
            try std.fmt.allocPrint(alloc, "{s}/zmx", .{xdg_runtime})
        else
            try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });
        errdefer alloc.free(socket_dir);

        const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{socket_dir});
        errdefer alloc.free(log_dir);

        var cfg = Cfg{
            .socket_dir = socket_dir,
            .log_dir = log_dir,
        };

        try cfg.mkdir();

        return cfg;
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

const SessionMetadata = struct {
    created_at: u64, // unix timestamp (ns) - all sessions
    task_exit_code: ?i32 = null, // null = running, set when task completes
    task_end_time: ?u64 = null, // timestamp when task exited
    task_command: []const u8 = "", // original task command string
};

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

    pub fn handleInput(self: *Daemon, pty_fd: i32, payload: []const u8) !void {
        _ = self;
        if (payload.len > 0) {
            _ = try posix.write(pty_fd, payload);
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

        var ws: c.struct_winsize = .{
            .ws_row = resize.rows,
            .ws_col = resize.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(pty_fd, c.TIOCSWINSZ, &ws);
        try term.resize(self.alloc, resize.cols, resize.rows);

        // Serialize terminal state BEFORE resize to capture correct cursor position.
        // Resizing triggers reflow which can move the cursor, and the shell's
        // SIGWINCH-triggered redraw will run after our snapshot is sent.
        // Only serialize on re-attach (has_had_client), not first attach, to avoid
        // interfering with shell initialization (DA1 queries, etc.)
        if (self.has_pty_output and self.has_had_client) {
            const cursor = &term.screens.active.cursor;
            std.log.debug("cursor before serialize: x={d} y={d} pending_wrap={}", .{ cursor.x, cursor.y, cursor.pending_wrap });
            if (serializeTerminalState(self.alloc, term)) |term_output| {
                std.log.debug("serialize terminal state", .{});
                defer self.alloc.free(term_output);
                ipc.appendMessage(self.alloc, &client.write_buf, .Output, term_output) catch |err| {
                    std.log.warn("failed to buffer terminal state for client err={s}", .{@errorName(err)});
                };
                client.has_pending_output = true;
            }
        }

        // Mark that we've had a client init, so subsequent clients get terminal state
        self.has_had_client = true;

        std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleResize(self: *Daemon, pty_fd: i32, term: *ghostty_vt.Terminal, payload: []const u8) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        var ws: c.struct_winsize = .{
            .ws_row = resize.rows,
            .ws_col = resize.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(pty_fd, c.TIOCSWINSZ, &ws);
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
        // gracefully shutdown shell processes, shells tend to ignore SIGTERM so we send SIGHUP instead
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

        // Build command string from args
        var cmd_buf: [ipc.MAX_CMD_LEN]u8 = undefined;
        var cmd_len: u16 = 0;
        const cur_cmd = self.command orelse self.task_command;
        if (cur_cmd) |args| {
            for (args, 0..) |arg, i| {
                if (i > 0) {
                    if (cmd_len < ipc.MAX_CMD_LEN) {
                        cmd_buf[cmd_len] = ' ';
                        cmd_len += 1;
                    }
                }
                const remaining = ipc.MAX_CMD_LEN - cmd_len;
                const copy_len: u16 = @intCast(@min(arg.len, remaining));
                @memcpy(cmd_buf[cmd_len..][0..copy_len], arg[0..copy_len]);
                cmd_len += copy_len;
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

    pub fn handleHistory(self: *Daemon, client: *Client, term: *ghostty_vt.Terminal, payload: []const u8) !void {
        const format: HistoryFormat = if (payload.len > 0)
            @enumFromInt(payload[0])
        else
            .plain;
        if (serializeTerminal(self.alloc, term, format)) |output| {
            defer self.alloc.free(output);
            try ipc.appendMessage(self.alloc, &client.write_buf, .History, output);
            client.has_pending_output = true;
        } else {
            try ipc.appendMessage(self.alloc, &client.write_buf, .History, "");
            client.has_pending_output = true;
        }
    }

    pub fn handleRun(self: *Daemon, client: *Client, pty_fd: i32, payload: []const u8) !void {
        if (payload.len > 0) {
            _ = try posix.write(pty_fd, payload);
        }
        try ipc.appendMessage(self.alloc, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        self.has_had_client = true;
        std.log.debug("run command len={d}", .{payload.len});
    }
};

pub fn main() !void {
    // use c_allocator to avoid "reached unreachable code" panic in DebugAllocator when forking
    const alloc = std.heap.c_allocator;

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
    } else if (std.mem.eql(u8, cmd, "kill") or std.mem.eql(u8, cmd, "k")) {
        const session_name = args.next() orelse "";
        const sesh = try getSeshName(alloc, session_name);
        defer alloc.free(sesh);
        return kill(&cfg, sesh);
    } else if (std.mem.eql(u8, cmd, "history") or std.mem.eql(u8, cmd, "hi")) {
        var session_name: ?[]const u8 = null;
        var format: HistoryFormat = .plain;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--vt")) {
                format = .vt;
            } else if (std.mem.eql(u8, arg, "--html")) {
                format = .html;
            } else if (session_name == null) {
                session_name = arg;
            }
        }
        const sesh = try getSeshName(alloc, session_name.?);
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

        const sesh = try getSeshName(alloc, session_name);
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
            .created_at = @intCast(std.time.nanoTimestamp()),
        };
        daemon.socket_path = try getSocketPath(alloc, cfg.socket_dir, sesh);
        std.log.info("socket path={s}", .{daemon.socket_path});
        return attach(&daemon);
    } else if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "r")) {
        const session_name = args.next() orelse "";

        var cmd_args_raw: std.ArrayList([]const u8) = .empty;
        defer cmd_args_raw.deinit(alloc);
        while (args.next()) |arg| {
            try cmd_args_raw.append(alloc, arg);
        }
        var cmd_args = try cmd_args_raw.clone(alloc);
        defer cmd_args.deinit(alloc);

        const shell = detectShell();
        // add a task completed marker so we know when the cmd is finished
        // we also capture the exit status
        if (std.mem.eql(u8, std.fs.path.basename(shell), "fish")) {
            // fish has special handling for capturing exit status
            try cmd_args.append(alloc, "; echo ZMX_TASK_COMPLETED:$status");
        } else {
            try cmd_args.append(alloc, "; echo ZMX_TASK_COMPLETED:$?");
        }
        const clients = try std.ArrayList(*Client).initCapacity(alloc, 10);

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch "";

        const sesh = try getSeshName(alloc, session_name);
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
            .created_at = @intCast(std.time.nanoTimestamp()),
            .is_task_mode = true,
            .task_command = cmd_args_raw.items,
        };
        daemon.socket_path = try getSocketPath(alloc, cfg.socket_dir, sesh);
        std.log.info("socket path={s}", .{daemon.socket_path});
        return run(&daemon, cmd_args.items);
    } else if (std.mem.eql(u8, cmd, "wait") or std.mem.eql(u8, cmd, "w")) {
        var args_raw: std.ArrayList([]const u8) = .empty;
        defer {
            args_raw.deinit(alloc);
            for (args_raw.items) |sesh| {
                alloc.free(sesh);
            }
        }
        while (args.next()) |session_name| {
            const sesh = try getSeshName(alloc, session_name);
            try args_raw.append(alloc, sesh);
        }
        return wait(&cfg, args_raw);
    } else {
        return help();
    }
}

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
        \\  [c]ompletions <shell>          Completion scripts for shell integration (bash, zsh, or fish)
        \\  [k]ill <name>                  Kill a session and all attached clients
        \\  [hi]story <name> [--vt|--html] Output session scrollback (--vt or --html for escape sequences)
        \\  [w]ait <name>...               Wait for session tasks to complete
        \\  [v]ersion                      Show version information
        \\  [h]elp                         Show this help message
        \\
        \\Environment variables:
        \\  - SHELL                Determines which shell is used when creating a session
        \\  - ZMX_DIR              Controls which folder is used to store unix socket files (prio: 1)
        \\  - XDG_RUNTIME_DIR      Controls which folder is used to store unix socket files (prio: 2)
        \\  - TMPDIR               Controls which folder is used to store unix socket files (prio: 3)
        \\  - ZMX_SESSION          This variable is injected into every zmx session automatically
        \\  - ZMX_SESSION_PREFIX   Adds this value to the start of every session name for all commands
        \\
    ;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(help_text, .{});
    try w.interface.flush();
}

const SessionEntry = struct {
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

    fn lessThan(_: void, a: SessionEntry, b: SessionEntry) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

fn wait(cfg: *Cfg, session_names: std.ArrayList([]const u8)) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    while (true) {
        var sessions = try get_session_entries(alloc, cfg);
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
            if (session.task_ended_at == 0) {
                try stdout.print("still waiting task={s}\n", .{session.name});
                try stdout.flush();
                continue;
            }
            if (session.task_exit_code != 0) {
                agg_exit_code = session.task_exit_code orelse 0;
            }
            done += 1;
        }

        session_entries_deinit(alloc, &sessions);

        if (total == done) {
            try stdout.print("tasks completed!\n", .{});
            try stdout.flush();
            std.process.exit(agg_exit_code);
            return;
        }

        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }
}

fn session_entries_deinit(alloc: std.mem.Allocator, sessions: *std.ArrayList(SessionEntry)) void {
    for (sessions.items) |session| {
        alloc.free(session.name);
        if (session.cmd) |cmd| alloc.free(cmd);
        if (session.cwd) |cwd| alloc.free(cwd);
    }
    sessions.deinit(alloc);
}

fn get_session_entries(alloc: std.mem.Allocator, cfg: *Cfg) !std.ArrayList(SessionEntry) {
    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();

    var sessions = try std.ArrayList(SessionEntry).initCapacity(alloc, 30);

    while (try iter.next()) |entry| {
        const exists = sessionExists(dir, entry.name) catch continue;
        if (exists) {
            const name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(name);

            const socket_path = try getSocketPath(alloc, cfg.socket_dir, entry.name);
            defer alloc.free(socket_path);

            const result = probeSession(alloc, socket_path) catch |err| {
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
                // cleanupStaleSocket(dir, entry.name);
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

const current_arrow = "→";

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
    var w = std.fs.File.stdout().writer(&buf);

    var sessions = try get_session_entries(alloc, cfg);
    defer session_entries_deinit(alloc, &sessions);

    if (sessions.items.len == 0) {
        if (short) return;
        try w.interface.print("no sessions found in {s}\n", .{cfg.socket_dir});
        try w.interface.flush();
        return;
    }

    std.mem.sort(SessionEntry, sessions.items, {}, SessionEntry.lessThan);

    for (sessions.items) |session| {
        try writeSessionLine(&w.interface, session, short, current_session);
        try w.interface.flush();
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

    const socket_path = try getSocketPath(alloc, cfg.socket_dir, session_name);
    defer alloc.free(socket_path);
    const result = probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        cleanupStaleSocket(dir, session_name);
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

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try sessionExists(dir, session_name);
    if (!exists) {
        std.log.err("cannot kill session because it does not exist session_name={s}", .{session_name});
        return;
    }

    const socket_path = try getSocketPath(alloc, cfg.socket_dir, session_name);
    defer alloc.free(socket_path);
    const result = probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        cleanupStaleSocket(dir, session_name);
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        w.interface.print("cleaned up stale session {s}\n", .{session_name}) catch {};
        w.interface.flush() catch {};
        return;
    };
    defer posix.close(result.fd);
    ipc.send(result.fd, .Kill, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("killed session {s}\n", .{session_name});
    try w.interface.flush();
}

const HistoryFormat = enum(u8) {
    plain = 0,
    vt = 1,
    html = 2,
};

fn history(cfg: *Cfg, session_name: []const u8, format: HistoryFormat) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try sessionExists(dir, session_name);
    if (!exists) {
        std.log.err("session does not exist session_name={s}", .{session_name});
        return;
    }

    const socket_path = try getSocketPath(alloc, cfg.socket_dir, session_name);
    defer alloc.free(socket_path);
    const result = probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        cleanupStaleSocket(dir, session_name);
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

const EnsureSessionResult = struct {
    created: bool,
    is_daemon: bool,
};

fn ensureSession(daemon: *Daemon) !EnsureSessionResult {
    var dir = try std.fs.openDirAbsolute(daemon.cfg.socket_dir, .{});
    defer dir.close();

    const exists = try sessionExists(dir, daemon.session_name);
    var should_create = !exists;

    if (exists) {
        if (probeSession(daemon.alloc, daemon.socket_path)) |result| {
            posix.close(result.fd);
            if (daemon.command != null) {
                std.log.warn("session already exists, ignoring command session={s}", .{daemon.session_name});
            }
        } else |_| {
            cleanupStaleSocket(dir, daemon.session_name);
            should_create = true;
        }
    }

    if (should_create) {
        std.log.info("creating session={s}", .{daemon.session_name});
        const server_sock_fd = try createSocket(daemon.socket_path);

        const pid = try posix.fork();
        if (pid == 0) { // child (daemon)
            _ = try posix.setsid();

            log_system.deinit();
            const session_log_name = try std.fmt.allocPrint(daemon.alloc, "{s}.log", .{daemon.session_name});
            defer daemon.alloc.free(session_log_name);
            const session_log_path = try std.fs.path.join(daemon.alloc, &.{ daemon.cfg.log_dir, session_log_name });
            defer daemon.alloc.free(session_log_path);
            try log_system.init(daemon.alloc, session_log_path);

            errdefer {
                posix.close(server_sock_fd);
                dir.deleteFile(daemon.session_name) catch {};
            }
            const pty_fd = try spawnPty(daemon);
            defer {
                posix.close(pty_fd);
                posix.close(server_sock_fd);
                std.log.info("deleting socket file session_name={s}", .{daemon.session_name});
                dir.deleteFile(daemon.session_name) catch |err| {
                    std.log.warn("failed to delete socket file err={s}", .{@errorName(err)});
                };
            }
            try daemonLoop(daemon, server_sock_fd, pty_fd);
            daemon.handleKill();
            _ = posix.waitpid(daemon.pid, 0);
            daemon.deinit();
            return .{ .created = true, .is_daemon = true };
        }
        posix.close(server_sock_fd);
        std.Thread.sleep(10 * std.time.ns_per_ms);
        return .{ .created = true, .is_daemon = false };
    }

    return .{ .created = false, .is_daemon = false };
}

fn attach(daemon: *Daemon) !void {
    if (std.posix.getenv("ZMX_SESSION")) |_| {
        return error.CannotAttachToSessionInSession;
    }

    const result = try ensureSession(daemon);
    if (result.is_daemon) return;

    const client_sock = try sessionConnect(daemon.socket_path);
    std.log.info("attached session={s}", .{daemon.session_name});
    //  this is typically used with tcsetattr() to modify terminal settings.
    //      - you first get the current settings with tcgetattr()
    //      - modify the desired attributes in the termios structure
    //      - then apply the changes with tcsetattr().
    //  This prevents unintended side effects by preserving other settings.
    var orig_termios: c.termios = undefined;
    _ = c.tcgetattr(posix.STDIN_FILENO, &orig_termios);

    // restore stdin fd to its original state after exiting.
    // Use TCSAFLUSH to discard any unread input, preventing stale input after detach.
    defer {
        _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSAFLUSH, &orig_termios);
        // Reset terminal modes on detach:
        // - Mouse: 1000=basic, 1002=button-event, 1003=any-event, 1006=SGR extended
        // - 2004=bracketed paste, 1004=focus events, 1049=alt screen
        // - 25h=show cursor
        // NOTE: We intentionally do NOT clear screen or home cursor here because we dont
        // want to corrupt any programs that rely on it including ghostty's session restore.
        const restore_seq = "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l" ++
            "\x1b[?2004l\x1b[?1004l\x1b[?1049l" ++
            "\x1b[?25h";
        _ = posix.write(posix.STDOUT_FILENO, restore_seq) catch {};
    }

    var raw_termios = orig_termios;
    //  set raw mode after successful connection.
    //      disables canonical mode (line buffering), input echoing, signal generation from
    //      control characters (like Ctrl+C), and flow control.
    c.cfmakeraw(&raw_termios);

    // Additional granular raw mode settings for precise control
    // (matches what abduco and shpool do)
    raw_termios.c_cc[c.VLNEXT] = c._POSIX_VDISABLE; // Disable literal-next (Ctrl-V)
    // We want to intercept Ctrl+\ (SIGQUIT) so we can use it as a detach key
    raw_termios.c_cc[c.VQUIT] = c._POSIX_VDISABLE; // Disable SIGQUIT (Ctrl+\)
    raw_termios.c_cc[c.VMIN] = 1; // Minimum chars to read: return after 1 byte
    raw_termios.c_cc[c.VTIME] = 0; // Read timeout: no timeout, return immediately

    _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &raw_termios);

    // Clear screen before attaching. This provides a clean slate before
    // the session restore.
    const clear_seq = "\x1b[2J\x1b[H";
    _ = try posix.write(posix.STDOUT_FILENO, clear_seq);

    try clientLoop(daemon.cfg, client_sock);
}

fn run(daemon: *Daemon, command_args: [][]const u8) !void {
    const alloc = daemon.alloc;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);

    const result = try ensureSession(daemon);
    if (result.is_daemon) return;

    if (result.created) {
        try w.interface.print("session \"{s}\" created\n", .{daemon.session_name});
        try w.interface.flush();
    }

    var cmd_to_send: ?[]const u8 = null;
    var allocated_cmd: ?[]u8 = null;
    defer if (allocated_cmd) |cmd| alloc.free(cmd);

    if (command_args.len > 0) {
        var total_len: usize = 0;
        for (command_args) |arg| {
            total_len += arg.len + 1;
        }

        const cmd_buf = try alloc.alloc(u8, total_len);
        allocated_cmd = cmd_buf;

        var offset: usize = 0;
        for (command_args, 0..) |arg, i| {
            @memcpy(cmd_buf[offset .. offset + arg.len], arg);
            offset += arg.len;
            if (i < command_args.len - 1) {
                cmd_buf[offset] = ' ';
            } else {
                cmd_buf[offset] = '\n';
            }
            offset += 1;
        }
        cmd_to_send = cmd_buf;
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
                const needs_newline = stdin_buf.items[stdin_buf.items.len - 1] != '\n';
                if (needs_newline) {
                    try stdin_buf.append(alloc, '\n');
                }
                cmd_to_send = try alloc.dupe(u8, stdin_buf.items);
                allocated_cmd = @constCast(cmd_to_send.?);
            }
        }
    }

    if (cmd_to_send == null) {
        return error.CommandRequired;
    }

    const probe_result = probeSession(alloc, daemon.socket_path) catch |err| {
        std.log.err("session not ready: {s}", .{@errorName(err)});
        return error.SessionNotReady;
    };
    defer posix.close(probe_result.fd);

    try ipc.send(probe_result.fd, .Run, cmd_to_send.?);

    var poll_fds = [_]posix.pollfd{.{ .fd = probe_result.fd, .events = posix.POLL.IN, .revents = 0 }};
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

fn clientLoop(_: *Cfg, client_sock_fd: i32) !void {
    // use c_allocator to avoid "reached unreachable code" panic in DebugAllocator when forking
    const alloc = std.heap.c_allocator;
    defer posix.close(client_sock_fd);

    setupSigwinchHandler();

    // Make socket non-blocking to avoid blocking on writes
    const sock_flags = try posix.fcntl(client_sock_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(client_sock_fd, posix.F.SETFL, sock_flags | posix.SOCK.NONBLOCK);

    // Buffer for outgoing socket writes
    var sock_write_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer sock_write_buf.deinit(alloc);

    // Send init message with terminal size (buffered)
    const size = getTerminalSize(posix.STDOUT_FILENO);
    try ipc.appendMessage(alloc, &sock_write_buf, .Init, std.mem.asBytes(&size));

    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(alloc, 4);
    defer poll_fds.deinit(alloc);

    var read_buf = try ipc.SocketBuffer.init(alloc);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer stdout_buf.deinit(alloc);

    const stdin_fd = posix.STDIN_FILENO;

    // Make stdin non-blocking
    const flags = try posix.fcntl(stdin_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(stdin_fd, posix.F.SETFL, flags | posix.SOCK.NONBLOCK);

    while (true) {
        // Check for pending SIGWINCH
        if (sigwinch_received.swap(false, .acq_rel)) {
            const next_size = getTerminalSize(posix.STDOUT_FILENO);
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
        if (poll_fds.items[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = posix.read(stdin_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                return err;
            };

            if (n_opt) |n| {
                if (n > 0) {
                    // Check for detach sequences (ctrl+\ as first byte or Kitty escape sequence)
                    if (buf[0] == 0x1C or isKittyCtrlBackslash(buf[0..n])) {
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

fn findTaskExitMarker(output: []const u8) ?u8 {
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

fn daemonLoop(daemon: *Daemon, server_sock_fd: i32, pty_fd: i32) !void {
    std.log.info("daemon started session={s} pty_fd={d}", .{ daemon.session_name, pty_fd });
    setupSigtermHandler();
    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(daemon.alloc, 8);
    defer poll_fds.deinit(daemon.alloc);

    const init_size = getTerminalSize(pty_fd);
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
            std.log.info("SIGTERM received, shutting down gracefully session={s}", .{daemon.session_name});
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
            return err;
        };

        if (poll_fds.items[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            std.log.err("server socket error revents={d}", .{poll_fds.items[0].revents});
            break :daemon_loop;
        } else if (poll_fds.items[0].revents & posix.POLL.IN != 0) {
            const client_fd = try posix.accept(server_sock_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
            const client = try daemon.alloc.create(Client);
            client.* = Client{
                .alloc = daemon.alloc,
                .socket_fd = client_fd,
                .read_buf = try ipc.SocketBuffer.init(daemon.alloc),
                .write_buf = undefined,
            };
            client.write_buf = try std.ArrayList(u8).initCapacity(client.alloc, 4096);
            try daemon.clients.append(daemon.alloc, client);
            std.log.info("client connected fd={d} total={d}", .{ client_fd, daemon.clients.items.len });
        }

        if (poll_fds.items[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
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

                    // In run mode, scan output for exit code marker
                    if (daemon.is_task_mode and daemon.task_exit_code == null) {
                        if (findTaskExitMarker(buf[0..n])) |exit_code| {
                            daemon.task_exit_code = exit_code;
                            daemon.task_ended_at = @intCast(std.time.nanoTimestamp());

                            std.log.info("task completed exit_code={d}", .{exit_code});
                            // Shell continues running - no break here
                        }
                    }

                    // Broadcast data to all clients
                    for (daemon.clients.items) |client| {
                        ipc.appendMessage(daemon.alloc, &client.write_buf, .Output, buf[0..n]) catch |err| {
                            std.log.warn("failed to buffer output for client err={s}", .{@errorName(err)});
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
            // If we have more clients than polled (i.e. we just accepted one), start from the polled ones
            i = num_polled_clients;
        }

        clients_loop: while (i > 0) {
            i -= 1;
            const client = daemon.clients.items[i];
            const revents = poll_fds.items[i + 2].revents;

            if (revents & posix.POLL.IN != 0) {
                const n = client.read_buf.read(client.socket_fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    std.log.debug("client read err={s} fd={d}", .{ @errorName(err), client.socket_fd });
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
                        .Input => try daemon.handleInput(pty_fd, msg.payload),
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

fn spawnPty(daemon: *Daemon) !c_int {
    const size = getTerminalSize(posix.STDOUT_FILENO);
    var ws: c.struct_winsize = .{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    var master_fd: c_int = undefined;
    const pid = forkpty(&master_fd, null, null, &ws);
    if (pid < 0) {
        return error.ForkPtyFailed;
    }

    if (pid == 0) { // child pid code path
        const session_env = try std.fmt.allocPrint(daemon.alloc, "ZMX_SESSION={s}\x00", .{daemon.session_name});
        _ = c.putenv(@ptrCast(session_env.ptr));

        if (daemon.command) |cmd_args| {
            const alloc = std.heap.c_allocator;
            var argv_buf: [64:null]?[*:0]const u8 = undefined;
            for (cmd_args, 0..) |arg, i| {
                argv_buf[i] = alloc.dupeZ(u8, arg) catch {
                    std.posix.exit(1);
                };
            }
            argv_buf[cmd_args.len] = null;
            const argv: [*:null]const ?[*:0]const u8 = &argv_buf;
            const err = std.posix.execvpeZ(argv_buf[0].?, argv, std.c.environ);
            std.log.err("execvpe failed: cmd={s} err={s}", .{ cmd_args[0], @errorName(err) });
            std.posix.exit(1);
        } else {
            const shell = detectShell();
            // Use "-shellname" as argv[0] to signal login shell (traditional method)
            var buf: [64]u8 = undefined;
            const login_shell = try std.fmt.bufPrintZ(&buf, "-{s}", .{std.fs.path.basename(shell)});
            const argv = [_:null]?[*:0]const u8{ login_shell, null };
            const err = std.posix.execveZ(shell, &argv, std.c.environ);
            std.log.err("execve failed: err={s}", .{@errorName(err)});
            std.posix.exit(1);
        }
    }
    // master pid code path
    daemon.pid = pid;
    std.log.info("pty spawned session={s} pid={d}", .{ daemon.session_name, pid });

    // make pty non-blocking
    const flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(master_fd, posix.F.SETFL, flags | @as(u32, 0o4000));
    return master_fd;
}

fn detectShell() [:0]const u8 {
    return std.posix.getenv("SHELL") orelse "/bin/sh";
}

fn seshPrefix() []const u8 {
    return std.posix.getenv("ZMX_SESSION_PREFIX") orelse "";
}

fn getSeshName(alloc: std.mem.Allocator, sesh: []const u8) ![]const u8 {
    const prefix = seshPrefix();
    if (std.mem.eql(u8, prefix, "") and std.mem.eql(u8, sesh, "")) {
        return error.SessionNameRequired;
    }
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ seshPrefix(), sesh });
}

fn sessionConnect(sesh: []const u8) !i32 {
    var unix_addr = try std.net.Address.initUnix(sesh);
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(socket_fd);
    try posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen());
    return socket_fd;
}

const SessionProbeError = error{
    Timeout,
    ConnectionRefused,
    Unexpected,
};

const SessionProbeResult = struct {
    fd: i32,
    info: ipc.Info,
};

fn probeSession(alloc: std.mem.Allocator, socket_path: []const u8) SessionProbeError!SessionProbeResult {
    const timeout_ms = 1000;
    const fd = sessionConnect(socket_path) catch |err| switch (err) {
        error.ConnectionRefused => return error.ConnectionRefused,
        else => return error.Unexpected,
    };
    errdefer posix.close(fd);

    ipc.send(fd, .Info, "") catch return error.Unexpected;

    var poll_fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const poll_result = posix.poll(&poll_fds, timeout_ms) catch return error.Unexpected;
    if (poll_result == 0) {
        return error.Timeout;
    }

    var sb = ipc.SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();

    const n = sb.read(fd) catch return error.Unexpected;
    if (n == 0) return error.Unexpected;

    while (sb.next()) |msg| {
        if (msg.header.tag == .Info) {
            if (msg.payload.len == @sizeOf(ipc.Info)) {
                return .{
                    .fd = fd,
                    .info = std.mem.bytesToValue(ipc.Info, msg.payload[0..@sizeOf(ipc.Info)]),
                };
            }
        }
    }
    return error.Unexpected;
}

fn cleanupStaleSocket(dir: std.fs.Dir, session_name: []const u8) void {
    std.log.warn("stale socket found, cleaning up session={s}", .{session_name});
    dir.deleteFile(session_name) catch |err| {
        std.log.warn("failed to delete stale socket err={s}", .{@errorName(err)});
    };
}

fn sessionExists(dir: std.fs.Dir, name: []const u8) !bool {
    const stat = dir.statFile(name) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket) {
        return error.FileNotUnixSocket;
    }
    return true;
}

fn createSocket(fname: []const u8) !i32 {
    // AF.UNIX: Unix domain socket for local IPC with client processes
    // SOCK.STREAM: Reliable, bidirectional communication
    // SOCK.NONBLOCK: Set socket to non-blocking
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);

    var unix_addr = try std.net.Address.initUnix(fname);
    try posix.bind(fd, &unix_addr.any, unix_addr.getOsSockLen());
    try posix.listen(fd, 128);
    return fd;
}

pub fn getSocketPath(alloc: std.mem.Allocator, socket_dir: []const u8, session_name: []const u8) ![]const u8 {
    const dir = socket_dir;
    const fname = try alloc.alloc(u8, dir.len + session_name.len + 1);
    @memcpy(fname[0..dir.len], dir);
    @memcpy(fname[dir.len .. dir.len + 1], "/");
    @memcpy(fname[dir.len + 1 ..], session_name);
    return fname;
}

fn handleSigwinch(_: i32, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    sigwinch_received.store(true, .release);
}

fn handleSigterm(_: i32, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    sigterm_received.store(true, .release);
}

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

fn getTerminalSize(fd: i32) ipc.Resize {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(fd, c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
    return .{ .rows = 24, .cols = 80 };
}

/// Formats a session entry for list output (only the name when `short` is
/// true), adding a prefix to indicate the current session, if there is one.
fn writeSessionLine(writer: *std.Io.Writer, session: SessionEntry, short: bool, current_session: ?[]const u8) !void {
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
        try writer.print("{s}session_name={s}\tstatus={s}\t(cleaning up)\n", .{
            prefix,
            session.name,
            session.error_name.?,
        });
        return;
    }

    try writer.print("{s}session_name={s}\tpid={d}\tclients={d}\tcreated_at={d}", .{
        prefix,
        session.name,
        session.pid.?,
        session.clients_len.?,
        session.created_at,
    });
    if (session.task_ended_at) |ended_at| {
        try writer.print("\ttask_ended_at={d}", .{ended_at});
    }
    if (session.task_exit_code) |exit_code| {
        try writer.print("\ttask_exit_code={d}", .{exit_code});
    }
    if (session.cwd) |cwd| {
        try writer.print("\tstarted_in={s}", .{cwd});
    }
    if (session.cmd) |cmd| {
        try writer.print("\tcmd={s}", .{cmd});
    }
    try writer.print("\n", .{});
}

/// Detects Kitty keyboard protocol escape sequence for Ctrl+\
/// 92 = backslash, 5 = ctrl modifier, :1 = key press event
fn isKittyCtrlBackslash(buf: []const u8) bool {
    return std.mem.indexOf(u8, buf, "\x1b[92;5u") != null or
        std.mem.indexOf(u8, buf, "\x1b[92;5:1u") != null;
}

fn serializeTerminalState(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal) ?[]const u8 {
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

fn serializeTerminal(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal, format: HistoryFormat) ?[]const u8 {
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

test "isKittyCtrlBackslash" {
    try std.testing.expect(isKittyCtrlBackslash("\x1b[92;5u"));
    try std.testing.expect(isKittyCtrlBackslash("\x1b[92;5:1u"));
    try std.testing.expect(!isKittyCtrlBackslash("\x1b[92;5:3u"));
    try std.testing.expect(!isKittyCtrlBackslash("\x1b[92;1u"));
    try std.testing.expect(!isKittyCtrlBackslash("garbage"));
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
            .expected = "→ session_name=dev\tpid=123\tclients=2\tcreated_at=0\n",
        },
        .{
            .session = session,
            .short = false,
            .current_session = "other",
            .expected = "  session_name=dev\tpid=123\tclients=2\tcreated_at=0\n",
        },
        .{
            .session = session,
            .short = false,
            .current_session = null,
            .expected = "session_name=dev\tpid=123\tclients=2\tcreated_at=0\n",
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
