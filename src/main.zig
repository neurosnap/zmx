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
        return attach(&cfg, session_name);
    } else {
        std.log.err("unknown cmd={s}", .{cmd});
    }
}

fn help() !void {
    std.log.info("running cmd=help", .{});
}

fn attach(cfg: *Cfg, name: []const u8) !void {
    std.log.info("running cmd=attach {s}", .{name});
    const fname = try socketPath(cfg, name);
    defer cfg.alloc.free(fname);
    std.log.info("socket path={s}", .{fname});

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try sessionExists(dir, name);
    if (exists) {
        std.log.info("reattaching to session: session_name={s}", .{name});
        const socket_fd = try sessionConnect(fname);
        std.log.info("unix socket connected: socket_fd={d}", .{socket_fd});
        // TODO: spawn client
        return;
    }

    std.log.info("creating session: session_name={s}", .{name});
    const fd = try createSocket(fname);
    defer {
        posix.close(fd);
        std.log.info("deleting socket file: fname={s}", .{fname});
        dir.deleteFile(name) catch {};
    }
    std.log.info("unix socket created: fd={d}", .{fd});

    const pid = try posix.fork();
    if (pid == 0) { // child
        _ = try posix.setsid();
        const socket_fd = try sessionConnect(fname);
        std.log.info("unix socket connected: socket_fd={d}", .{socket_fd});
        try spawnPty(cfg, name);
        // TODO: spawn daemon
        // TODO: spawn client
    } else { // parent
        const result = posix.waitpid(pid, 0);

        if (posix.W.IFEXITED(result.status)) {
            const exit_status = posix.W.EXITSTATUS(result.status);
            std.log.info("daemon exited with status: status={d}", .{exit_status});
        } else {
            std.log.err("daemon terminated abnormally", .{});
        }
    }
}

fn spawnPty(cfg: *Cfg, name: []const u8) !void {
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
        const session_env = try std.fmt.allocPrint(cfg.alloc, "ZMX_SESSION={s}\x00", .{name});
        _ = c.putenv(@ptrCast(session_env.ptr));

        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        const argv = [_:null]?[*:0]const u8{ shell, null };
        const err = std.posix.execveZ(shell, &argv, std.c.environ);
        std.log.err("execve failed: err={s}", .{@errorName(err)});
        std.posix.exit(1);
    }
    // master pid code path

    std.log.info("created pty session: session_name={s} master_pid={d} child_pid={d}", .{ name, master_fd, pid });

    // make pty non-blocking
    const flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(master_fd, posix.F.SETFL, flags | @as(u32, 0o4000));
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

fn socketPath(cfg: *Cfg, name: []const u8) ![]const u8 {
    const fname = try cfg.alloc.alloc(u8, cfg.socket_dir.len + name.len + 1);
    @memcpy(fname[0..cfg.socket_dir.len], cfg.socket_dir);
    @memcpy(fname[cfg.socket_dir.len .. cfg.socket_dir.len + 1], "/");
    @memcpy(fname[cfg.socket_dir.len + 1 ..], name);
    return fname;
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
