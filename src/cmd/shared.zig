const std = @import("std");
const log = @import("../log.zig");

pub var log_system = log.LogSystem{};

pub const O_NONBLOCK: usize = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");

pub var sig_pipe: [2]std.posix.fd_t = .{ -1, -1 };

pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn openSignalPipe() !void {
    sig_pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
}

pub fn drainSignalPipe() void {
    var b: [16]u8 = undefined;
    while (true) {
        const n = std.posix.read(sig_pipe[0], &b) catch return;
        if (n == 0) return;
    }
}

fn wakeSignalPipe(_: i32, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = std.c._errno().*;
    _ = std.c.write(sig_pipe[1], "x", 1);
    std.c._errno().* = saved;
}

pub fn installWakeHandler(sig: u6) void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = wakeSignalPipe },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO,
    };
    std.posix.sigaction(sig, &act, null);
}

pub fn ignoreSigpipe() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
}

pub fn setNonblocking(fd: i32) !usize {
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | O_NONBLOCK);
    return flags;
}

pub fn printUsage(cmd_name: []const u8, usage: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print("Usage: zmx {s} {s}\n", .{ cmd_name, usage });
    try w.interface.flush();
}
