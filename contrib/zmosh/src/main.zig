const std = @import("std");
const zmx = @import("libzmx");
const bootstrap = @import("bootstrap.zig");
const runtime = @import("runtime.zig");
const p = @import("posix.zig");

var log_file: ?std.Io.File = null;
var log_io: std.Io = undefined;

pub const std_options: std.Options = .{ .logFn = logFn };
fn logFn(comptime level: std.log.Level, comptime scope: anytype, comptime format: []const u8, args: anytype) void {
    if (log_file) |f| {
        var buf: [1024]u8 = undefined;
        var w = f.writer(log_io, &buf);
        w.interface.print("[{s}] ({s}): " ++ format ++ "\n", .{ @tagName(level), @tagName(scope) } ++ args) catch {};
        w.interface.flush() catch {};
    } else {
        if (p.getenv("ZMOSH_DEBUG") != null or level == .err) {
            std.log.defaultLog(level, scope, format, args);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    runtime.ignoreSigpipe();
    // A daemon fork must never unwind through parent-owned allocator/Io state,
    // including main's argument iterator and std.start's Init cleanup.
    const entry_pid = std.c.getpid();
    run(init, entry_pid) catch |err| {
        if (std.c.getpid() != entry_pid) p.exit(1);
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
    if (std.c.getpid() != entry_pid) p.exit(0);
}

fn run(init: std.process.Init, entry_pid: p.pid_t) !void {
    const alloc = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    defer if (std.c.getpid() == entry_pid) args.deinit();
    _ = args.next();
    const cmd = args.next() orelse return help();
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) return help();
    const is_attach = std.mem.eql(u8, cmd, "attach");
    const worker = std.mem.eql(u8, cmd, "--gateway");
    const is_serve = std.mem.eql(u8, cmd, "serve");
    if (!is_attach and !worker and !is_serve) return error.UnknownCommand;

    log_io = io;
    const log_dir = if (!is_serve) blk: {
        if (p.getenv("ZMX_DIR")) |zmxdir|
            break :blk std.fmt.allocPrint(alloc, "{s}/logs", .{zmxdir}) catch null
        else if (p.getenv("XDG_STATE_HOME")) |xdg_state_home|
            break :blk std.fmt.allocPrint(alloc, "{s}/zmx/logs", .{xdg_state_home}) catch null
        else if (p.getenv("HOME")) |home_dir|
            break :blk std.fmt.allocPrint(alloc, "{s}/.local/state/zmx/logs", .{home_dir}) catch null
        else
            break :blk null;
    } else null;

    if (log_dir) |dir| {
        defer alloc.free(dir);
        var it = std.fs.path.componentIterator(dir);
        var component = it.last();
        while (component) |c_val| {
            std.Io.Dir.createDirAbsolute(io, c_val.path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                error.FileNotFound => {
                    component = it.previous();
                    continue;
                },
                else => {},
            };
            component = it.next();
        }
        const log_path = std.fs.path.join(alloc, &.{ dir, "zmosh.log" }) catch null;
        if (log_path) |lp| {
            defer alloc.free(lp);
            log_file = std.Io.Dir.openFileAbsolute(io, lp, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => std.Io.Dir.createFileAbsolute(io, lp, .{ .read = true }) catch null,
                else => null,
            };
            if (log_file) |f| {
                _ = std.c.lseek(f.handle, 0, 2); // SEEK_END
            }
        }
    }
    defer if (log_file) |f| f.close(io);

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
        if (log_file) |f| {
            f.close(io);
            log_file = null;
        }
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
