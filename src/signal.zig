const std = @import("std");
const lib_posix = @import("posix.zig");

/// Self-pipe woken by signal handlers. std.posix.poll loops on .INTR internally
/// (PollError has no Interrupted member), so a signal that lands during poll()
/// never surfaces; the handler writes a byte here and poll() wakes on POLLIN.
pub var sig_pipe: [2]lib_posix.fd_t = .{ -1, -1 };

pub fn wakeSignalPipe(_: lib_posix.SIG, _: *const lib_posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = std.c._errno().*;
    _ = std.c.write(sig_pipe[1], "x", 1);
    std.c._errno().* = saved;
}

// std.posix.poll retries EINTR internally, so SA_RESTART is moot -- neither
// setting wakes the loop. The handler writes to sig_pipe instead; poll()
// wakes on its read end.
pub fn installWakeHandler(sig: u6) void {
    const act: lib_posix.Sigaction = .{
        .handler = .{ .sigaction = wakeSignalPipe },
        .mask = lib_posix.sigemptyset(),
        .flags = lib_posix.SA.SIGINFO,
    };
    lib_posix.sigaction(@as(lib_posix.SIG, @enumFromInt(sig)), &act, null);
}

pub fn ignoreSigpipe() void {
    const act: lib_posix.Sigaction = .{
        .handler = .{ .handler = lib_posix.SIG.IGN },
        .mask = lib_posix.sigemptyset(),
        .flags = 0,
    };
    lib_posix.sigaction(lib_posix.SIG.PIPE, &act, null);
}

pub fn openSignalPipe() !void {
    sig_pipe = try lib_posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
}

pub fn drainSignalPipe() void {
    var b: [16]u8 = undefined;
    while (true) {
        const n = lib_posix.read(sig_pipe[0], &b) catch return;
        if (n == 0) return;
    }
}
