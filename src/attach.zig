const std = @import("std");
const posix = std.posix;
const xevg = @import("xev");
const xev = xevg.Dynamic;
const clap = @import("clap");
const Config = @import("config.zig");
const protocol = @import("protocol.zig");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

pub fn main(cfg: *Config) !void {
    var thread_pool = xevg.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    var unix_addr = try std.net.Address.initUnix(cfg.socket_path);
    // AF.UNIX: Unix domain socket for local IPC with daemon process
    // SOCK.STREAM: Reliable, connection-oriented communication for protocol messages
    // SOCK.NONBLOCK: Prevents blocking to work with libxev's async event loop
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    // Save original terminal settings first (before connecting)
    var orig_termios: c.termios = undefined;
    _ = c.tcgetattr(posix.STDIN_FILENO, &orig_termios);

    posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen()) catch |err| {
        if (err == error.ConnectionRefused) {
            std.debug.print("Error: Unable to connect to zmx daemon at {s}\nPlease start the daemon first with: zmx daemon\n", .{cfg.socket_path});
            return err;
        }
        return err;
    };

    // Set raw mode after successful connection
    defer _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &orig_termios);

    var raw_termios = orig_termios;
    c.cfmakeraw(&raw_termios);
    _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &raw_termios);

    try loop.run(.until_done);
}
