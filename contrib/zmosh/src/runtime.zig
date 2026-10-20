const std = @import("std");
const p = @import("posix.zig");

pub var stopped: std.atomic.Value(bool) = .init(false);
pub var resized: std.atomic.Value(bool) = .init(false);

pub var sig_pipe: [2]p.fd_t = .{ -1, -1 };

pub fn wakeSignalPipe(_: p.SIG, _: *const p.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = std.c._errno().*;
    _ = std.c.write(sig_pipe[1], "x", 1);
    std.c._errno().* = saved;
}

pub fn openSignalPipe() !void {
    sig_pipe = try p.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
}

pub fn drainSignalPipe() void {
    var b: [16]u8 = undefined;
    while (true) {
        const n = p.read(sig_pipe[0], &b) catch return;
        if (n == 0) return;
    }
}

pub fn ignoreSigpipe() void {
    const act: p.Sigaction = .{
        .handler = .{ .handler = p.SIG.IGN },
        .mask = p.sigemptyset(),
        .flags = 0,
    };
    p.sigaction(p.SIG.PIPE, &act, null);
}

fn wake(sig: p.SIG, info: *const p.siginfo_t, context: ?*anyopaque) callconv(.c) void {
    if (sig == .WINCH) resized.store(true, .release) else stopped.store(true, .release);
    wakeSignalPipe(sig, info, context);
}

pub fn init() !void {
    stopped.store(false, .release);
    resized.store(false, .release);
    try openSignalPipe();
    const act: p.Sigaction = .{ .handler = .{ .sigaction = wake }, .mask = p.sigemptyset(), .flags = p.SA.SIGINFO };
    for ([_]p.SIG{ .WINCH, .TERM, .INT, .HUP }) |sig| p.sigaction(sig, &act, null);
}

pub fn deinit() void {
    if (sig_pipe[0] >= 0) p.close(sig_pipe[0]);
    if (sig_pipe[1] >= 0) p.close(sig_pipe[1]);
    sig_pipe = .{ -1, -1 };
}

pub fn nonblocking(fd: p.fd_t) !usize {
    const flags = try p.fcntl(fd, p.F.GETFL, 0);
    _ = try p.fcntl(fd, p.F.SETFL, flags | p.O_NONBLOCK);
    return flags;
}
