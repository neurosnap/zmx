const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const c = switch (builtin.os.tag) {
    .macos => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("util.h"); // openpty()
        @cInclude("stdlib.h");
    }),
    .freebsd => @cImport({
        @cInclude("termios.h"); // ioctl and constants
        @cInclude("libutil.h"); // openpty()
        @cInclude("stdlib.h");
    }),
    else => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("pty.h");
        @cInclude("stdlib.h");
    }),
};

// pub const std_options: std.Options = .{
//     .log_level = .err,
// };

const Client = struct {
    socket_fd: i32,
    has_pending_output: bool = false,
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
    if (exists) {
        std.log.info("reattaching to session: session_name={s}", .{daemon.session_name});
        _ = try sessionConnect(daemon.socket_path);
    } else {
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
    try clientLoop(client_sock);
}

fn clientLoop(client_sock_fd: i32) !void {
    // TODO: implement
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
            };
            try daemon.clients.append(daemon.alloc, client);
        }

        if (poll_fds.items[1].revents & posix.POLL.IN != 0) {
            // Read from PTY
            var buf: [4096]u8 = undefined;
            const n = posix.read(pty_fd, &buf) catch 0;
            if (n == 0) {
                // EOF: Shell exited
                should_exit = true;
            } else {
                // Broadcast data to all clients
                // If write blocks, buffer it and set client.has_pending_output
            }
        }

        var i: usize = daemon.clients.items.len;
        while (i > 0) {
            i -= 1;
            const client = daemon.clients.items[i];
            const revents = poll_fds.items[i + 2].revents;

            if (revents & posix.POLL.IN != 0) {
                // TODO: read from client
                // parse packets (attach, resize, input, detach)
                // if input -> write to pty
                // if resize -> ioctl(pty_fd, tiocswinsz, ...)
                // if detach/error -> close and remove client
            }

            if (revents & posix.POLL.OUT != 0) {
                // Flush pending output buffers
            }

            if (revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                posix.close(client.socket_fd);
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
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
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
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);

    var unix_addr = try std.net.Address.initUnix(fname);
    try posix.bind(fd, &unix_addr.any, unix_addr.getOsSockLen());
    try posix.listen(fd, 128);
    return fd;
}

fn list(_: *Cfg) !void {
    std.log.info("running cmd=list", .{});
}
