const std = @import("std");
const posix = std.posix;
const Cfg = @import("../cfg.zig").Cfg;
const shared = @import("shared.zig");
const ipc = @import("../ipc.zig");
const cross = @import("../cross.zig");
const socket = @import("../socket.zig");
const daemon_mod = @import("daemon.zig");
const client_loop = @import("client.zig");

const Daemon = daemon_mod.Daemon;

fn switchSesh(self: *Daemon, current_sesh: []const u8) !void {
    const next_session = self.session_name;
    const conn = shared.connectToSessionChecked(self.alloc, self.cfg.socket_dir, current_sesh) catch |err| switch (err) {
        error.SessionNotFound => {
            shared.printErr("error: session \"{s}\" does not exist\n", .{current_sesh}) catch {};
            return error.SessionNotFound;
        },
        error.ConnectionFailed => return,
    };
    defer conn.deinit();

    ipc.send(conn.fd, .Switch, next_session) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

fn attachImpl(daemon: *Daemon) !void {
    const sesh = socket.getSeshNameFromEnv();
    if (sesh.len > 0) {
        return switchSesh(daemon, sesh);
    }

    const result = try daemon.ensureSession();
    if (result.is_daemon) return;

    const client_sock = try socket.sessionConnect(daemon.socket_path);
    std.log.info("attached session={s}", .{daemon.session_name});

    var orig_termios: cross.c.termios = undefined;
    const stdin_is_tty = cross.c.tcgetattr(posix.STDIN_FILENO, &orig_termios) == 0;

    defer {
        if (stdin_is_tty) {
            _ = cross.c.tcsetattr(posix.STDIN_FILENO, cross.c.TCSAFLUSH, &orig_termios);
        }
        const restore_seq = "\x1bc";
        _ = posix.write(posix.STDOUT_FILENO, restore_seq) catch {};
    }

    if (stdin_is_tty) {
        var raw_termios = orig_termios;
        cross.c.cfmakeraw(&raw_termios);
        raw_termios.c_cc[cross.c.VLNEXT] = cross.c._POSIX_VDISABLE;
        raw_termios.c_cc[cross.c.VQUIT] = cross.c._POSIX_VDISABLE;
        raw_termios.c_cc[cross.c.VMIN] = 1;
        raw_termios.c_cc[cross.c.VTIME] = 0;
        _ = cross.c.tcsetattr(posix.STDIN_FILENO, cross.c.TCSANOW, &raw_termios);
    }

    const clear_seq = "\x1b[2J\x1b[H";
    _ = try posix.write(posix.STDOUT_FILENO, clear_seq);

    const looper = try client_loop.clientLoop(client_sock);
    switch (looper.kind) {
        .detach => return,
        .switch_session => {
            if (looper.session_name) |session_name| {
                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                const cwd = std.posix.getcwd(&cwd_buf) catch "";
                var target_daemon = try Daemon.init(daemon.alloc, daemon.cfg, session_name, null, cwd);
                return attachImpl(&target_daemon);
            }
        },
    }
}

pub fn cmdAttach(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const session_name = args.next() orelse "";
    if (shared.isHelp(session_name)) return shared.printUsage("attach", "<name> [command...]");
    var command_args: std.ArrayList([]const u8) = .empty;
    defer command_args.deinit(alloc);
    while (args.next()) |arg| try command_args.append(alloc, arg);

    const command: ?[][]const u8 = if (command_args.items.len > 0) command_args.items else null;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";

    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    var d = try Daemon.init(alloc, cfg, sesh, command, cwd);
    std.log.info("socket path={s}", .{d.socket_path});
    return attachImpl(&d);
}
