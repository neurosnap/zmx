const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const build_options = @import("build_options");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const log = @import("log.zig");

pub const version = build_options.version;

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
    socket_dir: []const u8 = "/tmp/zmx",
    log_dir: []const u8 = "/tmp/zmx/logs",
    max_scrollback: usize = 10_000_000,

    pub fn mkdir(self: *Cfg) !void {
        std.fs.makeDirAbsolute(self.socket_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        std.fs.makeDirAbsolute(self.log_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
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
    has_pty_output: bool = false,

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
};

pub fn main() !void {
    // use c_allocator to avoid "reached unreachable code" panic in DebugAllocator when forking
    const alloc = std.heap.c_allocator;

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.skip(); // skip program name

    var cfg = Cfg{};
    try cfg.mkdir();

    const log_path = try std.fs.path.join(alloc, &.{ cfg.log_dir, "zmx.log" });
    defer alloc.free(log_path);
    try log_system.init(alloc, log_path);
    defer log_system.deinit();

    const cmd = args.next() orelse {
        return list(&cfg);
    };

    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "--version")) {
        return printVersion();
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "-h")) {
        return help();
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "l")) {
        return list(&cfg);
    } else if (std.mem.eql(u8, cmd, "detach") or std.mem.eql(u8, cmd, "d")) {
        return detachAll(&cfg);
    } else if (std.mem.eql(u8, cmd, "kill") or std.mem.eql(u8, cmd, "k")) {
        const session_name = args.next() orelse {
            return error.SessionNameRequired;
        };
        return kill(&cfg, session_name);
    } else if (std.mem.eql(u8, cmd, "attach") or std.mem.eql(u8, cmd, "a")) {
        const session_name = args.next() orelse {
            return error.SessionNameRequired;
        };

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
        var daemon = Daemon{
            .running = true,
            .cfg = &cfg,
            .alloc = alloc,
            .clients = clients,
            .session_name = session_name,
            .socket_path = undefined,
            .pid = undefined,
            .command = command,
        };
        daemon.socket_path = try getSocketPath(alloc, cfg.socket_dir, session_name);
        std.log.info("socket path={s}", .{daemon.socket_path});
        return attach(&daemon);
    } else {
        return help();
    }
}

fn printVersion() !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("zmx {s}\n", .{version});
    try w.interface.flush();
}

fn help() !void {
    const help_text =
        \\zmx - session persistence for terminal processes
        \\
        \\Usage: zmx <command> [args]
        \\
        \\Commands:
        \\  [a]ttach <name> [command...]  Create or attach to a session
        \\  [d]etach                      Detach all clients from current session (ctrl+\ for current client)
        \\  [l]ist                        List active sessions
        \\  [k]ill <name>                 Kill a session and all attached clients
        \\  [v]ersion                     Show version information
        \\  [h]elp                        Show this help message
        \\
    ;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(help_text, .{});
    try w.interface.flush();
}

fn list(cfg: *Cfg) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    var hasSessions = false;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    while (try iter.next()) |entry| {
        const exists = sessionExists(dir, entry.name) catch continue;
        if (exists) {
            hasSessions = true;
            const socket_path = try getSocketPath(alloc, cfg.socket_dir, entry.name);
            defer alloc.free(socket_path);

            const result = probeSession(alloc, socket_path) catch |err| {
                w.interface.print("session_name={s}\tstatus={s}\t(cleaning up)\n", .{ entry.name, @errorName(err) }) catch {};
                w.interface.flush() catch {};
                cleanupStaleSocket(dir, entry.name);
                continue;
            };
            defer posix.close(result.fd);

            try w.interface.print("session_name={s}\tpid={d}\tclients={d}\n", .{ entry.name, result.info.pid, result.info.clients_len });
            try w.interface.flush();
        }
    }

    if (!hasSessions) {
        try w.interface.print("no sessions found in {s}\n", .{cfg.socket_dir});
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

fn attach(daemon: *Daemon) !void {
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
        if (pid == 0) { // child
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
            // Reap PTY child to prevent zombie
            _ = posix.waitpid(daemon.pid, 0);
            daemon.deinit();
            return;
        }
        posix.close(server_sock_fd);
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

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
        // Clear screen and show cursor on detach
        const restore_seq = "\x1b[?25h\x1b[2J\x1b[H";
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

    // Clear screen and move cursor to home before attaching
    const clear_seq = "\x1b[2J\x1b[H";
    _ = try posix.write(posix.STDOUT_FILENO, clear_seq);

    try clientLoop(daemon.cfg, client_sock);
}

fn clientLoop(_: *Cfg, client_sock_fd: i32) !void {
    // use c_allocator to avoid "reached unreachable code" panic in DebugAllocator when forking
    const alloc = std.heap.c_allocator;
    defer posix.close(client_sock_fd);

    setupSigwinchHandler();

    // Send init message with terminal size
    const size = getTerminalSize(posix.STDOUT_FILENO);
    ipc.send(client_sock_fd, .Init, std.mem.asBytes(&size)) catch {};

    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(alloc, 2);
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
            ipc.send(client_sock_fd, .Resize, std.mem.asBytes(&next_size)) catch |err| switch (err) {
                error.BrokenPipe, error.ConnectionResetByPeer => return,
                else => return err,
            };
        }

        poll_fds.clearRetainingCapacity();

        try poll_fds.append(alloc, .{
            .fd = stdin_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        });

        try poll_fds.append(alloc, .{
            .fd = client_sock_fd,
            .events = posix.POLL.IN,
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
                    // Check for Kitty keyboard protocol escape sequence for Ctrl+\
                    // Format: CSI 92 ; <modifiers> u  where modifiers has Ctrl bit (bit 2) set
                    // Examples: \e[92;5u (basic), \e[92;133u (with event flags)
                    if (isKittyCtrlBackslash(buf[0..n])) {
                        ipc.send(client_sock_fd, .Detach, "") catch |err| switch (err) {
                            error.BrokenPipe, error.ConnectionResetByPeer => return,
                            else => return err,
                        };
                        continue;
                    }

                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        if (buf[i] == 0x1C) { // Ctrl+\ (File Separator)
                            ipc.send(client_sock_fd, .Detach, "") catch |err| switch (err) {
                                error.BrokenPipe, error.ConnectionResetByPeer => return,
                                else => return err,
                            };
                        } else {
                            const payload = buf[i .. i + 1];
                            ipc.send(client_sock_fd, .Input, payload) catch |err| switch (err) {
                                error.BrokenPipe, error.ConnectionResetByPeer => return,
                                else => return err,
                            };
                        }
                    }
                } else {
                    // EOF on stdin
                    return;
                }
            }
        }

        // Handle socket -> stdout (Output)
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

fn daemonLoop(daemon: *Daemon, server_sock_fd: i32, pty_fd: i32) !void {
    std.log.info("daemon started session={s} pty_fd={d}", .{ daemon.session_name, pty_fd });
    var should_exit = false;
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

    while (!should_exit and daemon.running) {
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
            should_exit = true;
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
                    should_exit = true;
                } else {
                    // Feed PTY output to terminal emulator for state tracking
                    try vt_stream.nextSlice(buf[0..n]);
                    daemon.has_pty_output = true;

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
                    if (last) should_exit = true;
                    continue;
                };

                if (n == 0) {
                    // Client closed connection
                    const last = daemon.closeClient(client, i, false);
                    if (last) should_exit = true;
                    continue;
                }

                while (client.read_buf.next()) |msg| {
                    switch (msg.header.tag) {
                        .Input => {
                            if (msg.payload.len > 0) {
                                _ = try posix.write(pty_fd, msg.payload);
                            }
                        },
                        .Init => {
                            if (msg.payload.len == @sizeOf(ipc.Resize)) {
                                const resize = std.mem.bytesToValue(ipc.Resize, msg.payload);
                                var ws: c.struct_winsize = .{
                                    .ws_row = resize.rows,
                                    .ws_col = resize.cols,
                                    .ws_xpixel = 0,
                                    .ws_ypixel = 0,
                                };
                                _ = c.ioctl(pty_fd, c.TIOCSWINSZ, &ws);
                                try term.resize(daemon.alloc, resize.cols, resize.rows);
                                std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });

                                // Only send terminal state if there's been PTY output (skip on first attach)
                                if (daemon.has_pty_output) {
                                    var builder: std.Io.Writer.Allocating = .init(daemon.alloc);
                                    defer builder.deinit();
                                    var term_formatter = ghostty_vt.formatter.TerminalFormatter.init(&term, .vt);
                                    term_formatter.content = .{ .selection = null };
                                    term_formatter.extra = .{
                                        .palette = false, // Don't override host terminal's palette
                                        .modes = true,
                                        .scrolling_region = true,
                                        .tabstops = true,
                                        .pwd = true,
                                        .keyboard = true,
                                        .screen = .all,
                                    };
                                    term_formatter.format(&builder.writer) catch |err| {
                                        std.log.warn("failed to format terminal state err={s}", .{@errorName(err)});
                                    };
                                    const term_output = builder.writer.buffered();
                                    if (term_output.len > 0) {
                                        ipc.appendMessage(daemon.alloc, &client.write_buf, .Output, term_output) catch |err| {
                                            std.log.warn("failed to buffer terminal state for client err={s}", .{@errorName(err)});
                                        };
                                        client.has_pending_output = true;
                                    }
                                }
                            }
                        },
                        .Resize => {
                            if (msg.payload.len == @sizeOf(ipc.Resize)) {
                                const resize = std.mem.bytesToValue(ipc.Resize, msg.payload);
                                var ws: c.struct_winsize = .{
                                    .ws_row = resize.rows,
                                    .ws_col = resize.cols,
                                    .ws_xpixel = 0,
                                    .ws_ypixel = 0,
                                };
                                _ = c.ioctl(pty_fd, c.TIOCSWINSZ, &ws);
                                try term.resize(daemon.alloc, resize.cols, resize.rows);
                                std.log.debug("resize rows={d} cols={d}", .{ resize.rows, resize.cols });
                            }
                        },
                        .Detach => {
                            std.log.info("client detach fd={d}", .{client.socket_fd});
                            _ = daemon.closeClient(client, i, false);
                            break :clients_loop;
                        },
                        .DetachAll => {
                            std.log.info("detach all clients={d}", .{daemon.clients.items.len});
                            for (daemon.clients.items) |client_to_close| {
                                client_to_close.deinit();
                                daemon.alloc.destroy(client_to_close);
                            }
                            daemon.clients.clearRetainingCapacity();
                            break :clients_loop;
                        },
                        .Kill => {
                            std.log.info("kill received session={s}", .{daemon.session_name});
                            posix.kill(daemon.pid, posix.SIG.TERM) catch |err| {
                                std.log.warn("failed to send SIGTERM to pty child err={s}", .{@errorName(err)});
                            };
                            daemon.shutdown();
                            should_exit = true;
                            break :clients_loop;
                        },
                        .Info => {
                            // subtract current client since it's just fetching info
                            const clients_len = daemon.clients.items.len - 1;
                            const info = ipc.Info{
                                .clients_len = clients_len,
                                .pid = daemon.pid,
                            };
                            try ipc.appendMessage(daemon.alloc, &client.write_buf, .Info, std.mem.asBytes(&info));
                            client.has_pending_output = true;
                        },
                        .Output => {}, // Clients shouldn't send output
                    }
                }
            }

            if (revents & posix.POLL.OUT != 0) {
                // Flush pending output buffers
                const n = posix.write(client.socket_fd, client.write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    // Error on write, close client
                    const last = daemon.closeClient(client, i, false);
                    if (last) should_exit = true;
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
                if (last) should_exit = true;
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
            const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
            const argv = [_:null]?[*:0]const u8{ shell, null };
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

fn sessionConnect(fname: []const u8) !i32 {
    var unix_addr = try std.net.Address.initUnix(fname);
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

fn setupSigwinchHandler() void {
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO,
    };
    posix.sigaction(posix.SIG.WINCH, &act, null);
}

fn getTerminalSize(fd: i32) ipc.Resize {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(fd, c.TIOCGWINSZ, &ws) == 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
    return .{ .rows = 24, .cols = 80 };
}

/// Detects Kitty keyboard protocol escape sequence for Ctrl+\
/// Common sequences: \e[92;5u (basic), \e[92;133u (with event flags)
fn isKittyCtrlBackslash(buf: []const u8) bool {
    return std.mem.indexOf(u8, buf, "\x1b[92;5u") != null or
        std.mem.indexOf(u8, buf, "\x1b[92;133u") != null;
}

test "isKittyCtrlBackslash" {
    try std.testing.expect(isKittyCtrlBackslash("\x1b[92;5u"));
    try std.testing.expect(isKittyCtrlBackslash("\x1b[92;133u"));
    try std.testing.expect(!isKittyCtrlBackslash("\x1b[92;1u"));
    try std.testing.expect(!isKittyCtrlBackslash("\x1b[93;5u"));
    try std.testing.expect(!isKittyCtrlBackslash("garbage"));
}
