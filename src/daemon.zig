const std = @import("std");
const posix = std.posix;
const xevg = @import("xev");
const xev = xevg.Dynamic;
const clap = @import("clap");
const builtin = @import("builtin");
const ghostty = @import("ghostty-vt");

const Config = @import("config.zig");
const protocol = @import("protocol.zig");
const sgr = @import("sgr.zig");
const terminal_snapshot = @import("terminal_snapshot.zig");

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

const Ctx = struct {
    loop: *xev.Loop,
    cfg: *Config,
    accept_completion: xev.Completion,
};

pub fn main(cfg: *Config) !void {
    var thread_pool = xevg.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    std.log.info("zmx daemon starting\n", .{});
    std.log.info("socket_path: {s}\n", .{cfg.socket_path});

    std.log.info("deleting previous socket file\n", .{});
    _ = std.fs.cwd().deleteFile(cfg.socket_path) catch {};

    // AF.UNIX: Unix domain socket for local IPC with client processes
    // SOCK.STREAM: Reliable, bidirectional communication for JSON protocol messages
    // SOCK.NONBLOCK: Prevents blocking to work with libxev's async event loop
    const server_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    defer {
        posix.close(server_fd);
        std.log.info("deleting socket file\n", .{});
        std.fs.cwd().deleteFile(cfg.socket_path) catch {};
    }

    var unix_addr = std.net.Address.initUnix(cfg.socket_path) catch |err| {
        std.debug.print("initUnix failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try posix.bind(server_fd, &unix_addr.any, unix_addr.getOsSockLen());
    try posix.listen(server_fd, 128);

    var ctx = Ctx{
        .cfg = cfg,
        .loop = &loop,
        .accept_completion = .{},
    };
    const daemon_stream = xev.Stream.initFd(server_fd);
    daemon_stream.poll(
        &loop,
        &ctx.accept_completion,
        .read,
        Ctx,
        &ctx,
        acceptCallback,
    );

    try loop.run(.until_done);
}

fn acceptCallback(
    ctx_opt: ?*Ctx,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    poll_result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    _ = ctx_opt;
    _ = poll_result catch {};
    // Re-arm the poll
    return .rearm;
}
