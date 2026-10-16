const std = @import("std");
const zmx = @import("libzmx");
const bootstrap = @import("bootstrap.zig");
const p = zmx.posix;
pub const std_options: std.Options = .{ .logFn = logFn };
fn logFn(comptime level: std.log.Level, comptime scope: anytype, comptime format: []const u8, args: anytype) void {
    if (zmx.log.log_system.file == null) {
        if (p.getenv("ZMOSH_DEBUG") != null or level == .err) {
            std.log.defaultLog(level, scope, format, args);
        }
    } else {
        zmx.log.zmxLogFn(level, scope, format, args);
    }
}

pub fn main(init: std.process.Init) !void {
    zmx.signal.ignoreSigpipe();
    // A daemon fork must never unwind through parent-owned allocator/Io state,
    // including main's argument iterator and std.start's Init cleanup.
    const entry_pid = zmx.cross.c.getpid();
    run(init, entry_pid) catch |err| {
        if (zmx.cross.c.getpid() != entry_pid) p.exit(1);
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
    if (zmx.cross.c.getpid() != entry_pid) p.exit(0);
}

fn run(init: std.process.Init, entry_pid: p.pid_t) !void {
    const alloc = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    defer if (zmx.cross.c.getpid() == entry_pid) args.deinit();
    _ = args.next();
    const cmd = args.next() orelse return help();
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) return help();
    const is_attach = std.mem.eql(u8, cmd, "attach");
    const worker = std.mem.eql(u8, cmd, "--gateway");
    const is_serve = std.mem.eql(u8, cmd, "serve");
    if (!is_attach and !worker and !is_serve) return error.UnknownCommand;

    var cfg = try zmx.cfg.init(alloc, io);
    defer if (zmx.cross.c.getpid() == entry_pid) cfg.deinit(alloc);
    const log_path = try std.fs.path.join(alloc, &.{ cfg.log_dir, "zmosh.log" });
    defer if (zmx.cross.c.getpid() == entry_pid) alloc.free(log_path);
    try zmx.log.log_system.init(io, log_path, .fromMode(@intCast(cfg.log_mode)));
    defer if (zmx.cross.c.getpid() == entry_pid) zmx.log.log_system.deinit();

    if (is_attach) {
        const host = args.next() orelse return error.HostRequired;
        const session = args.next() orelse return error.SessionRequired;
        if (args.next() != null) return error.UnexpectedArgument;
        var remote = try bootstrap.connectRemote(alloc, io, host, session);
        defer remote.deinit(alloc);
        return @import("remote.zig").run(alloc, io, remote);
    }
    const raw_name = args.next() orelse return error.SessionRequired;
    if (args.next() != null) return error.UnexpectedArgument;
    if (worker) return @import("serve.zig").run(alloc, io, raw_name);
    if (comptime zmx.has_daemon) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const shell = init.environ_map.get("SHELL") orelse "/bin/sh";
        _ = try zmx.create(alloc, io, raw_name, .{
            .shell = shell,
            .cwd = cwd_buf[0..cwd_len],
            .quiet = true,
        });
    }
    // Pass the raw name: the worker applies the shared prefix exactly once.
    try bootstrap.startGateway(alloc, io, raw_name);
}
fn help() !void {
    _ = try p.write(1, "Usage: zmosh attach <host> <session>\n       zmosh serve <session>\n");
}
