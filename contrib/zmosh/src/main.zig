const std = @import("std");
const core = @import("zmx-core");
const bootstrap = @import("bootstrap.zig");
const p = core.posix;
pub const std_options: std.Options = .{ .logFn = logFn };
fn logFn(comptime level: std.log.Level, comptime scope: anytype, comptime format: []const u8, args: anytype) void {
    if (core.log.log_system.file == null) {
        std.log.defaultLog(level, scope, format, args);
    } else {
        core.log.zmxLogFn(level, scope, format, args);
    }
}

pub fn main(init: std.process.Init) !void {
    core.signal.ignoreSigpipe();
    // A daemon fork must never unwind through parent-owned allocator/Io state,
    // including main's argument iterator and std.start's Init cleanup.
    const entry_pid = core.cross.c.getpid();
    run(init, entry_pid) catch |err| {
        if (core.cross.c.getpid() != entry_pid) p.exit(1);
        // stderr may share the same saturated terminal as stdout. A final
        // diagnostic must not undo the client's bounded shutdown behavior.
        const flags = p.fcntl(2, p.F.GETFL, 0) catch p.exit(1);
        _ = p.fcntl(2, p.F.SETFL, flags | p.O_NONBLOCK) catch p.exit(1);
        var message: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&message, "zmosh: {s}\n", .{@errorName(err)}) catch "zmosh: failed\n";
        _ = p.write(2, text) catch 0;
        _ = p.fcntl(2, p.F.SETFL, flags) catch 0;
        p.exit(1);
    };
    if (core.cross.c.getpid() != entry_pid) p.exit(0);
}

fn run(init: std.process.Init, entry_pid: p.pid_t) !void {
    const alloc = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    defer if (core.cross.c.getpid() == entry_pid) args.deinit();
    _ = args.next();
    const cmd = args.next() orelse return help();
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) return help();
    if (std.mem.eql(u8, cmd, "attach")) {
        const host = args.next() orelse return error.HostRequired;
        const session = args.next() orelse return error.SessionRequired;
        if (args.next() != null) return error.UnexpectedArgument;
        var remote = try bootstrap.connectRemote(alloc, io, host, session);
        defer remote.deinit(alloc);
        return @import("remote.zig").run(alloc, io, remote);
    }
    const worker = std.mem.eql(u8, cmd, "--gateway");
    if (!worker and !std.mem.eql(u8, cmd, "serve")) return error.UnknownCommand;
    const raw_name = args.next() orelse return error.SessionRequired;
    if (args.next() != null) return error.UnexpectedArgument;
    var cfg = try core.cfg.init(alloc, io);
    defer if (core.cross.c.getpid() == entry_pid) cfg.deinit(alloc);
    const log_path = try std.fs.path.join(alloc, &.{ cfg.log_dir, "zmosh.log" });
    defer if (core.cross.c.getpid() == entry_pid) alloc.free(log_path);
    try core.log.log_system.init(io, log_path, .fromMode(@intCast(cfg.log_mode)));
    defer if (core.cross.c.getpid() == entry_pid) core.log.log_system.deinit();
    if (worker) return @import("serve.zig").run(alloc, io, raw_name);
    const name = try core.socket.getSeshName(alloc, raw_name);
    defer if (core.cross.c.getpid() == entry_pid) alloc.free(name);
    const path = try core.socket.getSocketPath(alloc, cfg.socket_dir, name);
    var daemon = core.Daemon.init(io, &cfg, name, path);
    defer if (core.cross.c.getpid() == entry_pid) daemon.deinit(alloc);
    daemon.shell = init.environ_map.get("SHELL") orelse "/bin/sh";
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
    daemon.setCwd(cwd_buf[0..cwd_len]);
    const saved_stdout = try p.fcntl(1, p.F.DUPFD_CLOEXEC, 3);
    defer if (core.cross.c.getpid() == entry_pid) p.close(@intCast(saved_stdout));
    try p.dup2(2, 1);
    const is_daemon = daemon.ensureSession(io) catch |err| {
        if (core.cross.c.getpid() != entry_pid) p.exit(1);
        try p.dup2(@intCast(saved_stdout), 1);
        return err;
    };
    if (is_daemon or core.cross.c.getpid() != entry_pid) p.exit(0);
    try p.dup2(@intCast(saved_stdout), 1);
    // Pass the raw name: the worker applies the shared prefix exactly once.
    try bootstrap.startGateway(alloc, io, raw_name);
}
fn help() !void {
    _ = try p.write(1, "Usage: zmosh attach <host> <session>\n       zmosh serve <session>\n");
}
