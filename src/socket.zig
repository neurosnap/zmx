const std = @import("std");
const posix = std.posix;

pub fn getSeshPrefix() []const u8 {
    return std.posix.getenv("ZMX_SESSION_PREFIX") orelse "";
}

pub fn getSeshNameFromEnv() []const u8 {
    return std.posix.getenv("ZMX_SESSION") orelse "";
}

pub fn getSeshName(alloc: std.mem.Allocator, sesh: []const u8) ![]const u8 {
    const prefix = getSeshPrefix();
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
    const fd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer posix.close(fd);

    var unix_addr = try std.net.Address.initUnix(fname);
    try posix.bind(fd, &unix_addr.any, unix_addr.getOsSockLen());
    try posix.listen(fd, 128);
    return fd;
}

/// Maximum number of usable bytes in a Unix domain socket path.
/// Derived from the platform's sockaddr_un.path field, minus 1 for the
/// required null terminator.
pub const max_socket_path_len: usize = @typeInfo(
    @TypeOf(@as(posix.sockaddr.un, undefined).path),
).array.len - 1;

pub fn getSocketPath(
    alloc: std.mem.Allocator,
    socket_dir: []const u8,
    session_name: []const u8,
) error{ NameTooLong, OutOfMemory }![]const u8 {
    const dir = socket_dir;
    const path_len = dir.len + 1 + session_name.len;
    if (path_len > max_socket_path_len) return error.NameTooLong;
    const fname = try alloc.alloc(u8, path_len);
    @memcpy(fname[0..dir.len], dir);
    @memcpy(fname[dir.len .. dir.len + 1], "/");
    @memcpy(fname[dir.len + 1 ..], session_name);
    return fname;
}

pub fn printSessionNameTooLong(session_name: []const u8, socket_dir: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    if (maxSessionNameLen(socket_dir)) |max_len| {
        w.interface.print(
            "error: session name is too long ({d} bytes, max {d} for socket directory \"{s}\")\n",
            .{ session_name.len, max_len, socket_dir },
        ) catch {};
    } else {
        w.interface.print(
            "error: socket directory path is too long (\"{s}\")\n",
            .{socket_dir},
        ) catch {};
    }
    w.interface.flush() catch {};
}

/// Returns the maximum session name length for a given socket directory,
/// or null if the socket directory itself is already too long.
pub fn maxSessionNameLen(socket_dir: []const u8) ?usize {
    // path = socket_dir + "/" + session_name
    const overhead = socket_dir.len + 1;
    if (overhead >= max_socket_path_len) return null;
    return max_socket_path_len - overhead;
}

test "max_socket_path_len matches platform sockaddr_un" {
    const path_field_len = @typeInfo(
        @TypeOf(@as(posix.sockaddr.un, undefined).path),
    ).array.len;
    try std.testing.expectEqual(path_field_len - 1, max_socket_path_len);
    try std.testing.expect(max_socket_path_len > 0);
}

test "getSocketPath succeeds for paths within limit" {
    const alloc = std.testing.allocator;
    const result = try getSocketPath(alloc, "/tmp/zmx", "mysession");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("/tmp/zmx/mysession", result);
}

test "getSocketPath returns NameTooLong when path exceeds limit" {
    const alloc = std.testing.allocator;
    const dir = [_]u8{'d'} ** (max_socket_path_len - 2);
    const dir_slice: []const u8 = &dir;

    const ok = try getSocketPath(alloc, dir_slice, "x");
    defer alloc.free(ok);
    try std.testing.expectEqual(max_socket_path_len, ok.len);

    const err = getSocketPath(alloc, dir_slice, "xx");
    try std.testing.expectError(error.NameTooLong, err);
}

test "getSocketPath returns NameTooLong for empty dir with oversized name" {
    const alloc = std.testing.allocator;
    const name = [_]u8{'n'} ** (max_socket_path_len);
    const name_slice: []const u8 = &name;
    const err = getSocketPath(alloc, "", name_slice);
    try std.testing.expectError(error.NameTooLong, err);
}

test "maxSessionNameLen computes correct dynamic limit" {
    const short_dir = "/tmp/zmx";
    const short_max = maxSessionNameLen(short_dir).?;
    try std.testing.expectEqual(max_socket_path_len - short_dir.len - 1, short_max);

    const full_dir = [_]u8{'f'} ** max_socket_path_len;
    const full_dir_slice: []const u8 = &full_dir;
    try std.testing.expectEqual(@as(?usize, null), maxSessionNameLen(full_dir_slice));

    const tight_dir = [_]u8{'t'} ** (max_socket_path_len - 2);
    const tight_dir_slice: []const u8 = &tight_dir;
    try std.testing.expectEqual(@as(?usize, 1), maxSessionNameLen(tight_dir_slice));
}

test "getSocketPath boundary: name fills exactly to limit" {
    const alloc = std.testing.allocator;
    const dir = "/tmp/zmx";
    const max_name_len = maxSessionNameLen(dir).?;

    const name_at_limit = try alloc.alloc(u8, max_name_len);
    defer alloc.free(name_at_limit);
    @memset(name_at_limit, 'a');

    const path = try getSocketPath(alloc, dir, name_at_limit);
    defer alloc.free(path);
    try std.testing.expectEqual(max_socket_path_len, path.len);

    const name_over_limit = try alloc.alloc(u8, max_name_len + 1);
    defer alloc.free(name_over_limit);
    @memset(name_over_limit, 'b');

    try std.testing.expectError(error.NameTooLong, getSocketPath(alloc, dir, name_over_limit));
}
