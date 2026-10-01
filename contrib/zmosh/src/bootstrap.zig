//! SSH bootstrap is deliberately separate from terminal and UDP handling.
const std = @import("std");
const zmx = @import("libzmx");
const p = zmx.posix;
const c = zmx.cross.c;
const crypto = @import("crypto.zig");

pub const RemoteSession = struct {
    host: []u8,
    port: u16,
    key: crypto.Key,
    pub fn deinit(self: *RemoteSession, alloc: std.mem.Allocator) void {
        alloc.free(self.host);
        std.crypto.secureZero(u8, &self.key);
    }
};
pub const Connect = struct { port: u16, key: crypto.Key };
pub fn parseConnectLine(line: []const u8) !Connect {
    const record = if (std.mem.endsWith(u8, line, "\n")) line[0 .. line.len - 1] else line;
    var it = std.mem.splitScalar(u8, record, ' ');
    if (!std.mem.eql(u8, it.next() orelse "", "ZMX_CONNECT")) return error.InvalidConnectLine;
    if (!std.mem.eql(u8, it.next() orelse "", "udp")) return error.InvalidConnectLine;
    const port_str = it.next() orelse return error.InvalidConnectLine;
    if (port_str.len == 0) return error.InvalidPort;
    for (port_str) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidPort;
    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    const key_str = it.next() orelse return error.InvalidConnectLine;
    if (it.next() != null or key_str.len != 44) return error.InvalidConnectLine;
    return .{ .port = port, .key = try crypto.keyFromBase64(key_str) };
}

pub fn quote(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidArgument;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('\'');
    for (value) |ch| {
        if (ch == '\'') try out.writer.writeAll("'\\''") else try out.writer.writeByte(ch);
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// Bounded read through EOF; a finite bootstrap must close its pipe.
fn readRecord(io: std.Io, fd: p.fd_t, buf: []u8, deadline: i64) ![]u8 {
    var used: usize = 0;
    while (true) {
        const remaining = deadline - now(io);
        if (remaining <= 0) return error.BootstrapTimeout;
        var fds = [_]p.pollfd{.{ .fd = fd, .events = p.POLL.IN, .revents = 0 }};
        if (try p.poll(&fds, @intCast(remaining)) == 0) return error.BootstrapTimeout;
        if (used == buf.len) return error.BootstrapTooLarge;
        const n = try p.read(fd, buf[used..]);
        if (n == 0) return buf[0..used];
        used += n;
    }
}

/// All storage is prepared before fork. Child performs only descriptor/process
/// operations and exec; it never uses inherited Zig allocator or Io state.
fn spawn(argv: [*:null]const ?[*:0]const u8, output: p.fd_t, detached: bool, max_fd: i32) !p.pid_t {
    const pid = try p.fork();
    if (pid != 0) return pid;
    if (detached) {
        _ = p.setsid() catch p.exit(1);
        const second = p.fork() catch p.exit(1);
        if (second != 0) p.exit(0);
    }
    const null_fd = p.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch p.exit(1);
    p.dup2(null_fd, 0) catch p.exit(1);
    p.dup2(output, 1) catch p.exit(1);
    if (detached) p.dup2(null_fd, 2) catch p.exit(1);
    var fd: i32 = 3;
    while (fd < max_fd) : (fd += 1) _ = std.c.close(fd);
    const exec_error = p.execvpeZ(argv[0].?, argv, std.c.environ);
    _ = @errorName(exec_error);
    p.exit(127);
}
fn fdLimit() i32 {
    const limit = c.sysconf(c._SC_OPEN_MAX);
    return if (limit > 0 and limit < std.math.maxInt(i32)) @intCast(limit) else 65536;
}
fn reap(io: std.Io, pid: p.pid_t, deadline: i64) !void {
    while (true) {
        const result = p.waitpid(pid, std.c.W.NOHANG);
        if (result.pid != 0) {
            if (result.status != 0) return error.BootstrapProcessFailed;
            return;
        }
        if (now(io) >= deadline) {
            p.kill(pid, .KILL) catch {};
            _ = p.waitpid(pid, 0);
            return error.BootstrapTimeout;
        }
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
}

pub fn connectRemote(alloc: std.mem.Allocator, io: std.Io, host: []const u8, session: []const u8) !RemoteSession {
    if (host.len == 0 or host[0] == '-' or std.mem.indexOfAny(u8, host, "\x00\r\n") != null) return error.InvalidHost;
    const term = try quote(alloc, p.getenv("TERM") orelse "xterm-256color");
    defer alloc.free(term);
    const color = try quote(alloc, p.getenv("COLORTERM") orelse "");
    defer alloc.free(color);
    const name = try quote(alloc, session);
    defer alloc.free(name);
    // SSH_CONNECTION is authenticated server-side metadata, and supplies the
    // destination address even when the user selected an SSH config alias.
    const command = try std.fmt.allocPrintSentinel(alloc, "TERM={s} COLORTERM={s} PATH=\"$PATH:/opt/homebrew/bin:$HOME/bin:$HOME/.local/bin\" zmosh serve {s} && {{ set -f; set -- $SSH_CONNECTION; printf 'ZMOSH_ADDRESS %s\\n' \"$3\"; }}", .{ term, color, name }, 0);
    defer alloc.free(command);
    const host_z = try alloc.dupeZ(u8, host);
    defer alloc.free(host_z);
    const port = p.getenv("ZMOSH_SSH_PORT") orelse "22";
    const port_num = std.fmt.parseInt(u16, port, 10) catch return error.InvalidPort;
    if (port_num == 0) return error.InvalidPort;
    const port_z = try alloc.dupeZ(u8, port);
    defer alloc.free(port_z);
    const argv = [_:null]?[*:0]const u8{ "ssh", "-T", "-o", "ConnectTimeout=15", "-p", port_z, "--", host_z, command };
    const pipe = try p.pipe2(.{ .CLOEXEC = true });
    defer p.close(pipe[0]);
    const pid = spawn(&argv, pipe[1], false, fdLimit()) catch |err| {
        p.close(pipe[1]);
        return err;
    };
    p.close(pipe[1]);
    var reaped = false;
    defer if (!reaped) {
        p.kill(pid, .KILL) catch {};
        _ = p.waitpid(pid, 0);
    };
    const deadline = now(io) + 15_000;
    var buf: [512]u8 = undefined;
    const record = try readRecord(io, pipe[0], &buf, deadline);
    // reap always consumes ownership, including a timeout/nonzero exit.
    reap(io, pid, deadline) catch |err| {
        reaped = true;
        return err;
    };
    reaped = true;
    var lines = std.mem.splitScalar(u8, record, '\n');
    const connect = try parseConnectLine(lines.next() orelse return error.InvalidConnectLine);
    const address = lines.next() orelse return error.InvalidAddress;
    const prefix = "ZMOSH_ADDRESS ";
    if (!std.mem.startsWith(u8, address, prefix)) return error.InvalidAddress;
    const ip = address[prefix.len..];
    // This contributed transport currently supports IPv4 only.
    _ = std.Io.net.Ip4Address.parse(ip, connect.port) catch return error.InvalidAddress;
    if (!std.mem.eql(u8, lines.next() orelse "missing", "") or lines.next() != null) return error.InvalidConnectLine;
    return .{ .host = try alloc.dupe(u8, ip), .port = connect.port, .key = connect.key };
}

pub fn startGateway(alloc: std.mem.Allocator, io: std.Io, session: []const u8) !void {
    const executable = try std.process.executablePathAlloc(io, alloc);
    defer alloc.free(executable);
    const name = try alloc.dupeZ(u8, session);
    defer alloc.free(name);
    const argv = [_:null]?[*:0]const u8{ executable, "--gateway", name };
    const pipe = try p.pipe2(.{ .CLOEXEC = true });
    defer p.close(pipe[0]);
    const pid = spawn(&argv, pipe[1], true, fdLimit()) catch |err| {
        p.close(pipe[1]);
        return err;
    };
    p.close(pipe[1]);
    const deadline = now(io) + 15_000;
    try reap(io, pid, deadline);
    var buf: [128]u8 = undefined;
    const record = try readRecord(io, pipe[0], &buf, deadline);
    _ = try parseConnectLine(record);
    var offset: usize = 0;
    while (offset < record.len) offset += try p.write(1, record[offset..]);
}

test "shell quote protects literal metacharacters and apostrophes" {
    const a = std.testing.allocator;
    const result = try quote(a, "a'b;$(touch /tmp/no)\n");
    defer a.free(result);
    try std.testing.expectEqualStrings("'a'\\''b;$(touch /tmp/no)\n'", result);
    try std.testing.expectError(error.InvalidArgument, quote(a, "x\x00y"));
}

test "connect record rejects malformed port key and trailing fields" {
    const key = crypto.keyToBase64(.{0} ** 32);
    var buf: [128]u8 = undefined;
    const valid = try std.fmt.bufPrint(&buf, "ZMX_CONNECT udp 1234 {s}\n", .{key});
    try std.testing.expectEqual(@as(u16, 1234), (try parseConnectLine(valid)).port);
    try std.testing.expectError(error.InvalidPort, parseConnectLine("ZMX_CONNECT udp 0 AAAA"));
    try std.testing.expectError(error.InvalidPort, parseConnectLine("ZMX_CONNECT udp +2 AAAA"));
    try std.testing.expectError(error.InvalidConnectLine, parseConnectLine("ZMX_CONNECT udp 2 AAAA"));
    const extra = try std.fmt.bufPrint(&buf, "ZMX_CONNECT udp 1234 {s} x", .{key});
    try std.testing.expectError(error.InvalidConnectLine, parseConnectLine(extra));
}

test "bootstrap rejects SSH option-like host before launching" {
    try std.testing.expectError(error.InvalidHost, connectRemote(std.testing.allocator, std.testing.io, "-oProxyCommand=bad", "session"));
}

test "bootstrap deadline bounds a silent pipe" {
    const pipe = try p.pipe2(.{ .CLOEXEC = true });
    defer p.close(pipe[0]);
    defer p.close(pipe[1]);
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.BootstrapTimeout, readRecord(std.testing.io, pipe[0], &buf, now(std.testing.io) + 10));
}

test "bootstrap reader bounds oversized output" {
    const pipe = try p.pipe2(.{ .CLOEXEC = true });
    defer p.close(pipe[0]);
    defer p.close(pipe[1]);
    _ = try p.write(pipe[1], "12345");
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.BootstrapTooLarge, readRecord(std.testing.io, pipe[0], &buf, now(std.testing.io) + 100));
}

test "bootstrap child is reaped after successful and failed exec" {
    const pipe = try p.pipe2(.{ .CLOEXEC = true });
    defer p.close(pipe[0]);
    defer p.close(pipe[1]);
    const success = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "exit 0" };
    const pid = try spawn(&success, pipe[1], false, 64);
    try reap(std.testing.io, pid, now(std.testing.io) + 2000);
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c_int, -1), std.c.waitpid(pid, &status, std.c.W.NOHANG));
    const failure = [_:null]?[*:0]const u8{"/does-not-exist-zmosh"};
    const failed_pid = try spawn(&failure, pipe[1], false, 64);
    try std.testing.expectError(error.BootstrapProcessFailed, reap(std.testing.io, failed_pid, now(std.testing.io) + 2000));
    try std.testing.expectEqual(@as(c_int, -1), std.c.waitpid(failed_pid, &status, std.c.W.NOHANG));
}

test "detached bootstrap supervisor is finite and reaped" {
    const pipe = try p.pipe2(.{ .CLOEXEC = true });
    defer p.close(pipe[0]);
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf detached" };
    const pid = try spawn(&argv, pipe[1], true, 64);
    p.close(pipe[1]);
    const deadline = now(std.testing.io) + 2000;
    try reap(std.testing.io, pid, deadline);
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c_int, -1), std.c.waitpid(pid, &status, std.c.W.NOHANG));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("detached", try readRecord(std.testing.io, pipe[0], &buf, deadline));
}

test "bootstrap reaps a child on deadline" {
    const pipe = try p.pipe2(.{ .CLOEXEC = true });
    defer p.close(pipe[0]);
    defer p.close(pipe[1]);
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "exec sleep 30" };
    const pid = try spawn(&argv, pipe[1], false, 64);
    try std.testing.expectError(error.BootstrapTimeout, reap(std.testing.io, pid, now(std.testing.io) + 10));
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c_int, -1), std.c.waitpid(pid, &status, std.c.W.NOHANG));
}

test "shell executes quoted hostile values literally" {
    const alloc = std.testing.allocator;
    const value = "value'; printf INJECTED; # $(printf expanded)\nnext";
    const quoted = try quote(alloc, value);
    defer alloc.free(quoted);
    const command = try std.fmt.allocPrintSentinel(alloc, "printf %s {s}", .{quoted}, 0);
    defer alloc.free(command);
    const pipe = try p.pipe2(.{ .CLOEXEC = true });
    defer p.close(pipe[0]);
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    const pid = try spawn(&argv, pipe[1], false, 64);
    p.close(pipe[1]);
    const deadline = now(std.testing.io) + 2000;
    try reap(std.testing.io, pid, deadline);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(value, try readRecord(std.testing.io, pipe[0], &buf, deadline));
}
