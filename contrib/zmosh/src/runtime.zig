const std = @import("std");
const core = @import("zmx-core");
const p = core.posix;

pub var stopped: std.atomic.Value(bool) = .init(false);
pub var resized: std.atomic.Value(bool) = .init(false);

fn wake(sig: p.SIG, info: *const p.siginfo_t, context: ?*anyopaque) callconv(.c) void {
    if (sig == .WINCH) resized.store(true, .release) else stopped.store(true, .release);
    core.signal.wakeSignalPipe(sig, info, context);
}

pub fn init() !void {
    stopped.store(false, .release);
    resized.store(false, .release);
    try core.signal.openSignalPipe();
    const act: p.Sigaction = .{ .handler = .{ .sigaction = wake }, .mask = p.sigemptyset(), .flags = p.SA.SIGINFO };
    for ([_]p.SIG{ .WINCH, .TERM, .INT, .HUP }) |sig| p.sigaction(sig, &act, null);
}

pub fn deinit() void {
    p.close(core.signal.sig_pipe[0]);
    p.close(core.signal.sig_pipe[1]);
    core.signal.sig_pipe = .{ -1, -1 };
}

pub fn nonblocking(fd: p.fd_t) !usize {
    const flags = try p.fcntl(fd, p.F.GETFL, 0);
    _ = try p.fcntl(fd, p.F.SETFL, flags | p.O_NONBLOCK);
    return flags;
}
