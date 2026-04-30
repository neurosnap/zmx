const std = @import("std");
const posix = std.posix;
const c = std.c;
const env = @import("env.zig");

pub const UnixAddr = struct {
    addr: c.sockaddr.un,

    pub fn init(path: []const u8) !UnixAddr {
        if (path.len >= @typeInfo(@TypeOf(@as(c.sockaddr.un, undefined).path)).array.len) return error.NameTooLong;
        var addr: c.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);
        return .{ .addr = addr };
    }

    pub fn sockaddr(self: *UnixAddr) *posix.sockaddr {
        return @ptrCast(&self.addr);
    }

    pub fn socklen(self: UnixAddr) posix.socklen_t {
        _ = self;
        return @sizeOf(c.sockaddr.un);
    }
};

pub fn close(fd: posix.fd_t) void {
    _ = c.close(fd);
}

pub const WriteError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    InvalidArgument,
    AccessDenied,
    BrokenPipe,
    ConnectionResetByPeer,
    WouldBlock,
    Unexpected,
};

pub fn write(fd: posix.fd_t, bytes: []const u8) WriteError!usize {
    const rc = c.write(fd, bytes.ptr, bytes.len);
    if (rc >= 0) return @intCast(rc);
    return switch (c.errno(rc)) {
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        .INVAL => error.InvalidArgument,
        .NOSPC => error.NoSpaceLeft,
        .IO => error.InputOutput,
        .ACCES => error.AccessDenied,
        .CONNRESET => error.ConnectionResetByPeer,
        .DQUOT => error.DiskQuota,
        .FBIG => error.FileTooBig,
        else => error.Unexpected,
    };
}

pub const O_NONBLOCK: u32 = @bitCast(c.O{ .NONBLOCK = true });

pub fn fcntl(fd: posix.fd_t, cmd: anytype, arg: u32) !u32 {
    const rc = c.fcntl(fd, @as(c_int, cmd), @as(c_int, @intCast(arg)));
    if (rc >= 0) return @intCast(rc);
    return error.Unexpected;
}

pub fn sleep(ns: u64) void {
    const duration: c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = c.nanosleep(&duration, null);
}

pub fn pipe2(flags: c.O) ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (c.pipe(&fds) < 0) return error.Unexpected;
    errdefer close(fds[0]);
    errdefer close(fds[1]);

    const flag_bits: u32 = @bitCast(flags);
    if (flag_bits & @as(u32, @bitCast(c.O{ .NONBLOCK = true })) != 0) {
        for (fds) |fd| {
            const fd_flags = try fcntl(fd, posix.F.GETFL, 0);
            _ = try fcntl(fd, posix.F.SETFL, fd_flags | O_NONBLOCK);
        }
    }
    if (flag_bits & @as(u32, @bitCast(c.O{ .CLOEXEC = true })) != 0) {
        for (fds) |fd| {
            const fd_flags = c.fcntl(fd, c.F.GETFD);
            if (fd_flags < 0) return error.Unexpected;
            if (c.fcntl(fd, c.F.SETFD, fd_flags | posix.FD_CLOEXEC) < 0) return error.Unexpected;
        }
    }

    return fds;
}

pub fn socket(domain: u32, sock_type: u32, protocol: u32) !posix.fd_t {
    const nonblock_bits: u32 = posix.SOCK.NONBLOCK;
    const cloexec_bits: u32 = posix.SOCK.CLOEXEC;
    const clean_type = sock_type & ~(nonblock_bits | cloexec_bits);
    const rc = c.socket(@intCast(domain), @intCast(clean_type), @intCast(protocol));
    if (rc < 0) return error.Unexpected;
    errdefer close(rc);

    if (sock_type & nonblock_bits != 0) {
        const flags = try fcntl(rc, posix.F.GETFL, 0);
        _ = try fcntl(rc, posix.F.SETFL, flags | O_NONBLOCK);
    }
    if (sock_type & cloexec_bits != 0) {
        const flags = c.fcntl(rc, c.F.GETFD);
        if (flags < 0) return error.Unexpected;
        if (c.fcntl(rc, c.F.SETFD, flags | posix.FD_CLOEXEC) < 0) return error.Unexpected;
    }

    return rc;
}

pub const ConnectError = error{
    ConnectionRefused,
    WouldBlock,
    Unexpected,
};

pub fn connect(fd: posix.fd_t, addr: *const posix.sockaddr, addrlen: posix.socklen_t) ConnectError!void {
    const rc = c.connect(fd, addr, addrlen);
    if (rc == 0) return;
    return switch (c.errno(rc)) {
        .CONNREFUSED => error.ConnectionRefused,
        .AGAIN, .INPROGRESS => error.WouldBlock,
        else => error.Unexpected,
    };
}

pub fn bind(fd: posix.fd_t, addr: *const posix.sockaddr, addrlen: posix.socklen_t) !void {
    const rc = c.bind(fd, addr, addrlen);
    if (rc == 0) return;
    return switch (c.errno(rc)) {
        .ADDRINUSE => error.AddressInUse,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

pub fn listen(fd: posix.fd_t, backlog: u31) !void {
    const rc = c.listen(fd, backlog);
    if (rc == 0) return;
    return error.Unexpected;
}

pub fn accept(fd: posix.fd_t, addr: ?*posix.sockaddr, addrlen: ?*posix.socklen_t, flags: u32) !posix.fd_t {
    const rc = c.accept(fd, addr, addrlen);
    if (rc < 0) return switch (c.errno(rc)) {
        .AGAIN => error.WouldBlock,
        else => error.Unexpected,
    };
    errdefer close(rc);

    if (flags & posix.SOCK.NONBLOCK != 0) {
        const fd_flags = try fcntl(rc, posix.F.GETFL, 0);
        _ = try fcntl(rc, posix.F.SETFL, fd_flags | O_NONBLOCK);
    }
    if (flags & posix.SOCK.CLOEXEC != 0) {
        const fd_flags = c.fcntl(rc, c.F.GETFD);
        if (fd_flags < 0) return error.Unexpected;
        if (c.fcntl(rc, c.F.SETFD, fd_flags | posix.FD_CLOEXEC) < 0) return error.Unexpected;
    }

    return rc;
}

pub fn fork() !posix.pid_t {
    const rc = c.fork();
    if (rc >= 0) return @intCast(rc);
    return error.Unexpected;
}

pub fn setsid() !posix.pid_t {
    const rc = c.setsid();
    if (rc >= 0) return @intCast(rc);
    return error.Unexpected;
}

pub fn dup2(old_fd: posix.fd_t, new_fd: posix.fd_t) !void {
    const rc = c.dup2(old_fd, new_fd);
    if (rc >= 0) return;
    return error.Unexpected;
}

pub const ExecError = error{
    FileNotFound,
    AccessDenied,
    NameTooLong,
    NotDir,
    InvalidExe,
    SystemResources,
    Unexpected,
};

fn execError(errno: c.E) ExecError {
    return switch (errno) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .NAMETOOLONG => error.NameTooLong,
        .NOTDIR => error.NotDir,
        .NOEXEC => error.InvalidExe,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

pub fn execveZ(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) ExecError {
    const rc = c.execve(path, argv, envp);
    return execError(c.errno(rc));
}

pub fn execvpeZ(
    alloc: std.mem.Allocator,
    file_z: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecError {
    const file = std.mem.span(file_z);
    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        return execveZ(file_z, argv, envp);
    }

    const path_env = env.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    var saw_access_denied = false;
    var dirs = std.mem.tokenizeScalar(u8, path_env, ':');
    while (dirs.next()) |dir| {
        const full_path = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, file }, 0) catch return error.SystemResources;
        const err = execveZ(full_path.ptr, argv, envp);
        alloc.free(full_path);
        switch (err) {
            error.FileNotFound, error.NotDir => continue,
            error.AccessDenied => {
                saw_access_denied = true;
                continue;
            },
            else => return err,
        }
    }
    return if (saw_access_denied) error.AccessDenied else error.FileNotFound;
}

pub const WaitPidResult = struct {
    pid: posix.pid_t,
    status: u32,
};

pub fn waitpid(pid: posix.pid_t, flags: u32) WaitPidResult {
    var status: c_int = 0;
    const rc = c.waitpid(pid, &status, @intCast(flags));
    return .{
        .pid = @intCast(rc),
        .status = @bitCast(status),
    };
}
