const std = @import("std");
const posix = std.posix;

pub fn seshPrefix() []const u8 {
    return std.posix.getenv("ZMX_SESSION_PREFIX") orelse "";
}

pub fn getSeshNameFromEnv() []const u8 {
    return std.posix.getenv("ZMX_SESSION") orelse "";
}

pub fn getSeshName(alloc: std.mem.Allocator, sesh: []const u8) ![]const u8 {
    const prefix = seshPrefix();
    if (prefix.len == 0 and sesh.len == 0) {
        return error.SessionNameRequired;
    }
    const full = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, sesh });
    // Session names become filenames under socket_dir. Rejecting path
    // separators and dot-dot prevents socket creation and stale-socket
    // deletion from operating outside that directory.
    if (std.mem.indexOfScalar(u8, full, '/') != null or
        std.mem.indexOfScalar(u8, full, 0) != null or
        std.mem.eql(u8, full, ".") or std.mem.eql(u8, full, ".."))
    {
        alloc.free(full);
        return error.InvalidSessionName;
    }
    return full;
}

pub fn sessionConnect(sesh: []const u8) !i32 {
    var unix_addr = try std.net.Address.initUnix(sesh);
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(socket_fd);
    try posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen());
    return socket_fd;
}

pub fn cleanupStaleSocket(dir: std.fs.Dir, session_name: []const u8) void {
    std.log.warn("stale socket found, cleaning up session={s}", .{session_name});
    dir.deleteFile(session_name) catch |err| {
        std.log.warn("failed to delete stale socket err={s}", .{@errorName(err)});
    };
}

pub fn sessionExists(dir: std.fs.Dir, name: []const u8) !bool {
    const stat = dir.statFile(name) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket) {
        return error.FileNotUnixSocket;
    }
    return true;
}

pub fn createSocket(fname: []const u8) !i32 {
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
