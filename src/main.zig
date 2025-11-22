const std = @import("std");
const posix = std.posix;
const ipc = @import("ipc.zig");
const builtin = @import("builtin");

const c = switch (builtin.os.tag) {
    .macos => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("util.h"); // openpty()
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

// pub const std_options: std.Options = .{
//     .log_level = .err,
// };

const Client = struct {
    socket_fd: i32,
    has_pending_output: bool = false,
    read_buf: ipc.SocketBuffer,
    write_buf: std.ArrayList(u8),
};

const Cfg = struct {
    socket_dir: []const u8 = "/tmp/zmx",
    alloc: std.mem.Allocator,

    pub fn mkdir(self: *Cfg) !void {
        std.log.info("creating socket dir: socket_dir={s}", .{self.socket_dir});
        std.fs.makeDirAbsolute(self.socket_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.log.info("socket dir already exists", .{});
            },
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

    pub fn deinit(self: *Daemon) void {
        self.clients.deinit(self.alloc);
        self.alloc.free(self.socket_path);
    }

    pub fn setSocketPath(self: *Daemon) !void {
        const dir = self.cfg.socket_dir;
        const fname = try self.alloc.alloc(u8, dir.len + self.session_name.len + 1);
        @memcpy(fname[0..dir.len], dir);
        @memcpy(fname[dir.len .. dir.len + 1], "/");
        @memcpy(fname[dir.len + 1 ..], self.session_name);
        self.socket_path = fname;
    }
};

pub fn main() !void {
    std.log.info("running cli", .{});
    // use c_allocator to avoid "reached unreachable code" panic in DebugAllocator when forking
    const alloc = std.heap.c_allocator;

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.skip(); // skip program name

    var cfg = Cfg{
        .alloc = alloc,
    };
    try cfg.mkdir();

    const cmd = args.next() orelse {
        return list(&cfg);
    };

    if (std.mem.eql(u8, cmd, "help")) {
        return help();
    } else if (std.mem.eql(u8, cmd, "attach")) {
        const session_name = args.next() orelse {
            std.log.err("session name required", .{});
            return;
        };
        const clients = try std.ArrayList(*Client).initCapacity(alloc, 10);
        var daemon = Daemon{
            .cfg = &cfg,
            .alloc = alloc,
            .clients = clients,
            .session_name = session_name,
            .socket_path = undefined,
        };
        try daemon.setSocketPath();
        std.log.info("socket path={s}", .{daemon.socket_path});
        return attach(&daemon);
    } else {
        std.log.err("unknown cmd={s}", .{cmd});
    }
}

fn help() !void {
    std.log.info("running cmd=help", .{});
}

fn attach(daemon: *Daemon) !void {
    std.log.info("running cmd=attach {s}", .{daemon.session_name});

    var dir = try std.fs.openDirAbsolute(daemon.cfg.socket_dir, .{});
    defer dir.close();

    const exists = try sessionExists(dir, daemon.session_name);
    var should_create = !exists;

    if (exists) {
        std.log.info("reattaching to session: session_name={s}", .{daemon.session_name});
        const fd = sessionConnect(daemon.socket_path) catch |err| switch (err) {
            error.ConnectionRefused => blk: {
                std.log.warn("stale socket found, cleaning up: fname={s}", .{daemon.socket_path});
                try dir.deleteFile(daemon.socket_path);
                should_create = true;
                break :blk -1;
            },
            else => return err,
        };
        if (fd != -1) {
            posix.close(fd);
        }
    }

    if (should_create) {
        std.log.info("creating session: session_name={s}", .{daemon.session_name});
        const server_sock_fd = try createSocket(daemon.socket_path);
        std.log.info("unix socket created: server_sock_fd={d}", .{server_sock_fd});

        const pid = try posix.fork();
        if (pid == 0) { // child
            _ = try posix.setsid();
            const pty_fd = try spawnPty(daemon);
            defer {
                posix.close(server_sock_fd);
                std.log.info("deleting socket file: fname={s}", .{daemon.socket_path});
                dir.deleteFile(daemon.socket_path) catch {};
            }
            try daemonLoop(daemon, server_sock_fd, pty_fd);
            std.process.exit(0);
        }
        posix.close(server_sock_fd);
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const client_sock = try sessionConnect(daemon.socket_path);

    //  this is typically used with tcsetattr() to modify terminal settings.
    //      - you first get the current settings with tcgetattr()
    //      - modify the desired attributes in the termios structure
    //      - then apply the changes with tcsetattr().
    //  This prevents unintended side effects by preserving other settings.
    var orig_termios: c.termios = undefined;
    _ = c.tcgetattr(posix.STDIN_FILENO, &orig_termios);

    // restore stdin fd to its original state and exit alternate buffer after exiting.
    defer {
        _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &orig_termios);
        // Restore normal buffer and show cursor
        const restore_seq = "\x1b[?25h\x1b[?1049l";
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
    raw_termios.c_cc[c.VMIN] = 1; // Minimum chars to read: return after 1 byte
    raw_termios.c_cc[c.VTIME] = 0; // Read timeout: no timeout, return immediately

    _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &raw_termios);

    // Switch to alternate screen buffer and home cursor
    // This prevents session output from polluting the terminal after detach
    const alt_buffer_seq = "\x1b[?1049h\x1b[H";
    _ = try posix.write(posix.STDOUT_FILENO, alt_buffer_seq);

    try clientLoop(client_sock);
}

fn clientLoop(client_sock_fd: i32) !void {
    // use c_allocator to avoid "reached unreachable code" panic in DebugAllocator when forking
    const alloc = std.heap.c_allocator;

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
            if (err == error.SystemResources) continue;
            return err;
        };

        // Handle stdin -> socket (Input)
        if (poll_fds.items[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = posix.read(stdin_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                return err;
            };

            if (n_opt) |n| {
                if (n > 0) {
                    ipc.send(client_sock_fd, .Input, buf[0..n]) catch |err| switch (err) {
                        error.BrokenPipe, error.ConnectionResetByPeer => return,
                        else => return err,
                    };
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
                    std.log.info("client: daemon disconnected", .{});
                    return;
                }
                std.log.err("client: read error from daemon: {s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) {
                std.log.info("client: daemon closed connection", .{});
                return; // Server closed connection
            }

            const Ctx = struct {
                buf: *std.ArrayList(u8),
                alloc: std.mem.Allocator,
            };
            try read_buf.process(Ctx{ .buf = &stdout_buf, .alloc = alloc }, struct {
                fn handler(ctx: Ctx, header: ipc.Header, payload: []u8) !void {
                    switch (header.tag) {
                        .Output => {
                            if (payload.len > 0) {
                                try ctx.buf.appendSlice(ctx.alloc, payload);
                            }
                        },
                        else => {},
                    }
                }
            }.handler);
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
    var should_exit = false;
    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(daemon.alloc, 8);
    defer poll_fds.deinit(daemon.alloc);

    while (!should_exit) {
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
            if (err == error.SystemResources) {
                // Interrupted by signal (EINTR) - check flags (e.g. child exit) and continue
                continue;
            }
            return err;
        };

        if (poll_fds.items[0].revents & posix.POLL.IN != 0) {
            const client_fd = try posix.accept(server_sock_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
            const client = try daemon.alloc.create(Client);
            client.* = Client{
                .socket_fd = client_fd,
                .read_buf = try ipc.SocketBuffer.init(daemon.alloc),
                .write_buf = try std.ArrayList(u8).initCapacity(daemon.alloc, 4096),
            };
            try daemon.clients.append(daemon.alloc, client);
        }

        if (poll_fds.items[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
            // Read from PTY
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = posix.read(pty_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                break :blk 0;
            };

            if (n_opt) |n| {
                if (n == 0) {
                    // EOF: Shell exited
                    std.log.info("pty: shell exited", .{});
                    should_exit = true;
                } else {
                    // Broadcast data to all clients
                    for (daemon.clients.items) |client| {
                        ipc.appendMessage(daemon.alloc, &client.write_buf, .Output, buf[0..n]) catch |err| {
                            std.log.warn("failed to buffer output for client: err={s}", .{@errorName(err)});
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

        while (i > 0) {
            i -= 1;
            const client = daemon.clients.items[i];
            const revents = poll_fds.items[i + 2].revents;

            if (revents & posix.POLL.IN != 0) {
                const n = client.read_buf.read(client.socket_fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    std.log.warn("client read error: err={s}", .{@errorName(err)});
                    // Force close on error
                    posix.close(client.socket_fd);
                    client.read_buf.deinit();
                    client.write_buf.deinit(daemon.alloc);
                    daemon.alloc.destroy(client);
                    _ = daemon.clients.orderedRemove(i);
                    continue;
                };

                if (n == 0) {
                    // Client closed connection
                    posix.close(client.socket_fd);
                    client.read_buf.deinit();
                    client.write_buf.deinit(daemon.alloc);
                    daemon.alloc.destroy(client);
                    _ = daemon.clients.orderedRemove(i);
                    continue;
                }

                const Ctx = struct {
                    pty_fd: i32,
                };
                try client.read_buf.process(Ctx{ .pty_fd = pty_fd }, struct {
                    fn handler(ctx: Ctx, header: ipc.Header, payload: []u8) !void {
                        switch (header.tag) {
                            .Input => {
                                if (payload.len > 0) {
                                    _ = try posix.write(ctx.pty_fd, payload);
                                }
                            },
                            .Resize => {
                                if (payload.len == @sizeOf(ipc.Resize)) {
                                    const resize = std.mem.bytesToValue(ipc.Resize, payload);
                                    var ws: c.struct_winsize = .{
                                        .ws_row = resize.rows,
                                        .ws_col = resize.cols,
                                        .ws_xpixel = 0,
                                        .ws_ypixel = 0,
                                    };
                                    _ = c.ioctl(ctx.pty_fd, c.TIOCSWINSZ, &ws);
                                }
                            },
                            .Output => {}, // Clients shouldn't send output
                            .Pid => {}, // Clients shouldn't send pid
                        }
                    }
                }.handler);
            }

            if (revents & posix.POLL.OUT != 0) {
                // Flush pending output buffers
                const n = posix.write(client.socket_fd, client.write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    // Error on write, close client
                    posix.close(client.socket_fd);
                    client.read_buf.deinit();
                    client.write_buf.deinit(daemon.alloc);
                    daemon.alloc.destroy(client);
                    _ = daemon.clients.orderedRemove(i);
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
                posix.close(client.socket_fd);
                client.read_buf.deinit();
                client.write_buf.deinit(daemon.alloc);
                daemon.alloc.destroy(client);
                _ = daemon.clients.orderedRemove(i);
            }
        }
    }
}

fn spawnPty(daemon: *Daemon) !c_int {
    // Get terminal size
    var orig_ws: c.struct_winsize = undefined;
    const result = c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &orig_ws);
    const rows: u16 = if (result == 0) orig_ws.ws_row else 24;
    const cols: u16 = if (result == 0) orig_ws.ws_col else 80;
    var ws: c.struct_winsize = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    var master_fd: c_int = undefined;
    const pid = c.forkpty(&master_fd, null, null, &ws);
    if (pid < 0) {
        return error.ForkPtyFailed;
    }

    if (pid == 0) { // child pid code path
        const session_env = try std.fmt.allocPrint(daemon.alloc, "ZMX_SESSION={s}\x00", .{daemon.session_name});
        _ = c.putenv(@ptrCast(session_env.ptr));

        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        const argv = [_:null]?[*:0]const u8{ shell, null };
        const err = std.posix.execveZ(shell, &argv, std.c.environ);
        std.log.err("execve failed: err={s}", .{@errorName(err)});
        std.posix.exit(1);
    }
    // master pid code path

    std.log.info("created pty session: session_name={s} master_pid={d} child_pid={d}", .{ daemon.session_name, master_fd, pid });

    // make pty non-blocking
    const flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(master_fd, posix.F.SETFL, flags | @as(u32, 0o4000));
    return master_fd;
}

fn sessionConnect(fname: []const u8) !i32 {
    var unix_addr = try std.net.Address.initUnix(fname);
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen()) catch |err| {
        if (err == error.ConnectionRefused) {
            std.log.err("unable to connect to unix socket: fname={s}", .{fname});
            return err;
        }
        return err;
    };
    std.log.info("unix socket connected: client_socket_fd={d}", .{socket_fd});
    return socket_fd;
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

    var unix_addr = try std.net.Address.initUnix(fname);
    try posix.bind(fd, &unix_addr.any, unix_addr.getOsSockLen());
    try posix.listen(fd, 128);
    return fd;
}

fn list(_: *Cfg) !void {
    std.log.info("running cmd=list", .{});
}
