const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const completions = @import("completions.zig");
const util = @import("util.zig");
const cross = @import("cross.zig");
const socket = @import("socket.zig");

pub const version = build_options.version;
pub const ghostty_version = build_options.ghostty_version;

var log_system = log.LogSystem{};

pub const std_options: std.Options = .{
    .logFn = zmxLogFn,
    .log_level = .debug,
};

fn zmxLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    log_system.log(level, scope, format, args);
}

/// Self-pipe woken by signal handlers. std.posix.poll loops on .INTR internally
/// (PollError has no Interrupted member), so a signal that lands during poll()
/// never surfaces; the handler writes a byte here and poll() wakes on POLLIN.
var sig_pipe: [2]posix.fd_t = .{ -1, -1 };

// https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/std/posix.zig#L3505
const O_NONBLOCK: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");

const SessionMatch = struct {
    name: []const u8,
    is_prefix: bool,

    fn matches(self: SessionMatch, session_name: []const u8) bool {
        if (self.is_prefix) return std.mem.startsWith(u8, session_name, self.name);
        return std.mem.eql(u8, session_name, self.name);
    }
};

fn parseSessionArg(alloc: std.mem.Allocator, raw: []const u8) !SessionMatch {
    if (raw.len > 0 and raw[raw.len - 1] == '*') {
        const name = try socket.getSeshName(alloc, raw[0 .. raw.len - 1]);
        return .{ .name = name, .is_prefix = true };
    }
    const name = try socket.getSeshName(alloc, raw);
    return .{ .name = name, .is_prefix = false };
}

fn openSignalPipe() !void {
    sig_pipe = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
}

fn drainSignalPipe() void {
    var b: [16]u8 = undefined;
    while (true) {
        const n = posix.read(sig_pipe[0], &b) catch return;
        if (n == 0) return;
    }
}

const ArgCompletion = enum { none, sessions, shells };

const FlagDef = struct {
    name: []const u8,
    short: ?[]const u8 = null,
    description: []const u8,
};

const CmdDef = struct {
    name: []const u8,
    aliases: []const []const u8,
    help_line: []const u8,
    run: *const fn (std.mem.Allocator, *Cfg, *std.process.ArgIterator) anyerror!void,
    next_arg: ArgCompletion,
    flags: []const FlagDef,
};

const Command = enum {
    attach,
    run,
    send,
    print,
    write,
    detach,
    list,
    kill,
    history,
    wait,
    tail,
    completions,
    version,
    help,

    fn fromName(name: []const u8) ?Command {
        const map = std.StaticStringMap(Command).initComptime(.{
            .{ "attach", .attach },
            .{ "a", .attach },
            .{ "run", .run },
            .{ "r", .run },
            .{ "send", .send },
            .{ "s", .send },
            .{ "print", .print },
            .{ "p", .print },
            .{ "write", .write },
            .{ "wr", .write },
            .{ "detach", .detach },
            .{ "d", .detach },
            .{ "list", .list },
            .{ "l", .list },
            .{ "ls", .list },
            .{ "kill", .kill },
            .{ "k", .kill },
            .{ "history", .history },
            .{ "hi", .history },
            .{ "wait", .wait },
            .{ "w", .wait },
            .{ "tail", .tail },
            .{ "t", .tail },
            .{ "completions", .completions },
            .{ "c", .completions },
            .{ "version", .version },
            .{ "v", .version },
            .{ "-v", .version },
            .{ "--version", .version },
            .{ "help", .help },
            .{ "h", .help },
            .{ "-h", .help },
        });
        return map.get(name);
    }

    fn meta(self: Command) CmdDef {
        return switch (self) {
            .attach => .{
                .name = "attach",
                .aliases = &.{"a"},
                .help_line = "<name> [command...]  Attach to session, creating if needed",
                .run = cmdAttach,
                .next_arg = .sessions,
                .flags = &.{},
            },
            .run => .{
                .name = "run",
                .aliases = &.{"r"},
                .help_line = "<name> [-d] [command...]  Send command without attaching",
                .run = cmdRun,
                .next_arg = .sessions,
                .flags = &.{.{ .name = "-d", .description = "Detach from the calling terminal" }},
            },
            .send => .{
                .name = "send",
                .aliases = &.{"s"},
                .help_line = "<name> <text...>  Send raw input to session PTY",
                .run = cmdSend,
                .next_arg = .sessions,
                .flags = &.{},
            },
            .print => .{
                .name = "print",
                .aliases = &.{"p"},
                .help_line = "<name> <text...>  Inject text into session display",
                .run = cmdPrint,
                .next_arg = .sessions,
                .flags = &.{},
            },
            .write => .{
                .name = "write",
                .aliases = &.{"wr"},
                .help_line = "<name> <file_path>  Write stdin to file_path through the session",
                .run = cmdWrite,
                .next_arg = .sessions,
                .flags = &.{},
            },
            .detach => .{
                .name = "detach",
                .aliases = &.{"d"},
                .help_line = "Detach all clients (ctrl+\\ for current client)",
                .run = cmdDetach,
                .next_arg = .none,
                .flags = &.{},
            },
            .list => .{
                .name = "list",
                .aliases = &.{ "l", "ls" },
                .help_line = "[--short]  List active sessions",
                .run = cmdList,
                .next_arg = .none,
                .flags = &.{.{ .name = "--short", .description = "Short output: session names only" }},
            },
            .kill => .{
                .name = "kill",
                .aliases = &.{"k"},
                .help_line = "<name>... [--force]  Kill session and all attached clients",
                .run = cmdKill,
                .next_arg = .sessions,
                .flags = &.{.{ .name = "--force", .description = "Force kill" }},
            },
            .history => .{
                .name = "history",
                .aliases = &.{"hi"},
                .help_line = "<name> [--vt|--html]  Output session scrollback",
                .run = cmdHistory,
                .next_arg = .sessions,
                .flags = &.{ .{ .name = "--vt", .description = "VT escape sequence format" }, .{ .name = "--html", .description = "HTML format" } },
            },
            .wait => .{
                .name = "wait",
                .aliases = &.{"w"},
                .help_line = "<name>...  Wait for session tasks to complete",
                .run = cmdWait,
                .next_arg = .sessions,
                .flags = &.{},
            },
            .tail => .{
                .name = "tail",
                .aliases = &.{"t"},
                .help_line = "<name>...  Follow session output",
                .run = cmdTail,
                .next_arg = .sessions,
                .flags = &.{},
            },
            .completions => .{
                .name = "completions",
                .aliases = &.{"c"},
                .help_line = "<shell>  Shell completions (bash, zsh, fish, nu)",
                .run = cmdCompletions,
                .next_arg = .shells,
                .flags = &.{},
            },
            .version => .{
                .name = "version",
                .aliases = &.{ "v", "-v", "--version" },
                .help_line = "Show version and metadata",
                .run = cmdVersion,
                .next_arg = .none,
                .flags = &.{},
            },
            .help => .{
                .name = "help",
                .aliases = &.{ "h", "-h" },
                .help_line = "Show this help",
                .run = cmdHelp,
                .next_arg = .none,
                .flags = &.{},
            },
        };
    }
};

const ALL_COMMANDS: []const CmdDef = &[_]CmdDef{
    Command.attach.meta(),
    Command.run.meta(),
    Command.send.meta(),
    Command.print.meta(),
    Command.write.meta(),
    Command.detach.meta(),
    Command.list.meta(),
    Command.kill.meta(),
    Command.history.meta(),
    Command.wait.meta(),
    Command.tail.meta(),
    Command.completions.meta(),
    Command.version.meta(),
    Command.help.meta(),
};

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn cmdList(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    var short = false;
    if (args.next()) |arg| {
        if (isHelp(arg)) return cmdHelp(alloc, cfg, args);
        short = std.mem.eql(u8, arg, "--short");
    }
    return list(cfg, short);
}

fn cmdCompletions(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const arg = args.next() orelse return;
    if (isHelp(arg)) return cmdHelp(alloc, cfg, args);
    const shell = completions.Shell.fromString(arg) orelse return;
    return printCompletions(shell);
}

fn cmdDetach(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    _ = alloc;
    _ = args;
    return detachAll(cfg);
}

fn cmdHistory(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    var session_name: ?[]const u8 = null;
    var format: util.HistoryFormat = .plain;
    while (args.next()) |arg| {
        if (isHelp(arg)) return cmdHelp(alloc, cfg, args);
        if (std.mem.eql(u8, arg, "--vt")) {
            format = .vt;
        } else if (std.mem.eql(u8, arg, "--html")) {
            format = .html;
        } else if (session_name == null) {
            session_name = arg;
        }
    }
    const sesh_env = socket.getSeshNameFromEnv();
    const sesh = try socket.getSeshName(alloc, session_name orelse sesh_env);
    defer alloc.free(sesh);
    return history(cfg, sesh, format);
}

fn cmdAttach(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const session_name = args.next() orelse "";
    if (isHelp(session_name)) return cmdHelp(alloc, cfg, args);

    var command_args: std.ArrayList([]const u8) = .empty;
    defer command_args.deinit(alloc);
    while (args.next()) |arg| try command_args.append(alloc, arg);

    const clients = try std.ArrayList(*Client).initCapacity(alloc, 10);
    const command: ?[][]const u8 = if (command_args.items.len > 0) command_args.items else null;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";

    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    var daemon = Daemon{
        .running = true,
        .cfg = cfg,
        .alloc = alloc,
        .clients = clients,
        .session_name = sesh,
        .socket_path = undefined,
        .pid = undefined,
        .command = command,
        .cwd = cwd,
        .created_at = @intCast(std.time.timestamp()),
        .leader_client_fd = null,
    };
    daemon.socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    std.log.info("socket path={s}", .{daemon.socket_path});
    return attach(&daemon);
}

fn cmdRun(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const session_name = args.next() orelse "";
    if (isHelp(session_name)) return cmdHelp(alloc, cfg, args);

    var cmd_args_raw: std.ArrayList([]const u8) = .empty;
    defer cmd_args_raw.deinit(alloc);
    var detached = false;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-d")) {
            detached = true;
            continue;
        }
        try cmd_args_raw.append(alloc, arg);
    }
    const clients = try std.ArrayList(*Client).initCapacity(alloc, 10);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";

    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    var daemon = Daemon{
        .running = true,
        .cfg = cfg,
        .alloc = alloc,
        .clients = clients,
        .session_name = sesh,
        .socket_path = undefined,
        .pid = undefined,
        .command = null,
        .cwd = cwd,
        .created_at = @intCast(std.time.timestamp()),
        .is_task_mode = true,
        .leader_client_fd = null,
    };
    daemon.socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    std.log.info("socket path={s}", .{daemon.socket_path});
    return run(&daemon, detached, cmd_args_raw.items);
}

fn cmdSend(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const session_name = args.next() orelse "";
    if (isHelp(session_name)) return cmdHelp(alloc, cfg, args);
    if (session_name.len == 0) return error.SessionNameRequired;

    var text_parts: std.ArrayList([]const u8) = .empty;
    defer text_parts.deinit(alloc);
    while (args.next()) |arg| try text_parts.append(alloc, arg);

    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    return send(cfg, sesh, socket_path, text_parts.items, .Input);
}

fn cmdPrint(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const session_name = args.next() orelse "";
    if (isHelp(session_name)) return cmdHelp(alloc, cfg, args);
    if (session_name.len == 0) return error.SessionNameRequired;

    var text_parts: std.ArrayList([]const u8) = .empty;
    defer text_parts.deinit(alloc);
    while (args.next()) |arg| try text_parts.append(alloc, arg);

    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    return send(cfg, sesh, socket_path, text_parts.items, .Output);
}

fn cmdKill(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    var matchers: std.ArrayList(SessionMatch) = .empty;
    defer {
        for (matchers.items) |m| alloc.free(m.name);
        matchers.deinit(alloc);
    }
    var force = false;
    while (args.next()) |arg| {
        if (isHelp(arg)) return cmdHelp(alloc, cfg, args);
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
            continue;
        }
        try matchers.append(alloc, try parseSessionArg(alloc, arg));
    }
    if (matchers.items.len == 0) return error.SessionNameRequired;

    var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
    defer {
        for (sessions.items) |session| session.deinit(alloc);
        sessions.deinit(alloc);
    }
    for (sessions.items) |session| {
        for (matchers.items) |m| {
            if (!m.matches(session.name)) continue;
            kill(cfg, session.name, force) catch |err| {
                try stderr.print("failed to kill session={s}: {s}\n", .{ session.name, @errorName(err) });
                try stderr.flush();
            };
            break;
        }
    }
}

fn cmdWait(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    var matchers: std.ArrayList(SessionMatch) = .empty;
    defer {
        for (matchers.items) |m| alloc.free(m.name);
        matchers.deinit(alloc);
    }
    while (args.next()) |arg| {
        if (isHelp(arg)) return cmdHelp(alloc, cfg, args);
        try matchers.append(alloc, try parseSessionArg(alloc, arg));
    }
    if (matchers.items.len == 0) return error.SessionNameRequired;
    return wait(cfg, matchers);
}

fn cmdTail(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    var matchers: std.ArrayList(SessionMatch) = .empty;
    defer {
        for (matchers.items) |m| alloc.free(m.name);
        matchers.deinit(alloc);
    }
    while (args.next()) |arg| {
        if (isHelp(arg)) return cmdHelp(alloc, cfg, args);
        try matchers.append(alloc, try parseSessionArg(alloc, arg));
    }
    if (matchers.items.len == 0) return error.SessionNameRequired;

    var resolved_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (resolved_names.items) |name| alloc.free(name);
        resolved_names.deinit(alloc);
    }

    var any_prefix = false;
    for (matchers.items) |m| {
        if (m.is_prefix) {
            any_prefix = true;
            break;
        }
    }

    if (any_prefix) {
        var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
        defer {
            for (sessions.items) |session| session.deinit(alloc);
            sessions.deinit(alloc);
        }
        for (sessions.items) |session| {
            for (matchers.items) |m| {
                if (m.matches(session.name)) {
                    try resolved_names.append(alloc, try alloc.dupe(u8, session.name));
                    break;
                }
            }
        }
    }
    for (matchers.items) |m| {
        if (!m.is_prefix) try resolved_names.append(alloc, try alloc.dupe(u8, m.name));
    }

    var client_socket_fds = try std.ArrayList(i32).initCapacity(alloc, resolved_names.items.len);
    defer {
        for (client_socket_fds.items) |fd| posix.close(fd);
        client_socket_fds.deinit(alloc);
    }
    for (resolved_names.items) |session_name| {
        const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
            error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
            error.OutOfMemory => return err,
        };
        try client_socket_fds.append(alloc, try socket.sessionConnect(socket_path));
    }
    _ = try tail(client_socket_fds, false, false);
}

fn cmdWrite(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const session_name = args.next() orelse "";
    if (isHelp(session_name)) return cmdHelp(alloc, cfg, args);
    if (session_name.len == 0) return error.SessionNameRequired;
    const file_path = args.next() orelse "";
    if (isHelp(file_path)) return cmdHelp(alloc, cfg, args);
    if (file_path.len == 0) return error.FilePathRequired;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";
    const clients = try std.ArrayList(*Client).initCapacity(alloc, 10);
    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    var daemon = Daemon{
        .running = true,
        .cfg = cfg,
        .alloc = alloc,
        .clients = clients,
        .session_name = sesh,
        .socket_path = undefined,
        .pid = undefined,
        .command = null,
        .cwd = cwd,
        .created_at = @intCast(std.time.timestamp()),
        .is_task_mode = true,
        .leader_client_fd = null,
    };
    daemon.socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    std.log.info("socket path={s}", .{daemon.socket_path});
    try writeFile(&daemon, file_path);
}

fn cmdVersion(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    _ = alloc;
    _ = args;
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("zmx\t\t{s}\nghostty_vt\t{s}\nsocket_dir\t{s}\nlog_dir\t\t{s}\n", .{ version, ghostty_version, cfg.socket_dir, cfg.log_dir });
    try w.interface.flush();
}

fn cmdHelp(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    _ = alloc;
    _ = cfg;
    _ = args;
    try help();
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    ignoreSigpipe();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.skip();

    var cfg = try Cfg.init(alloc);
    defer cfg.deinit(alloc);

    const log_path = try std.fs.path.join(alloc, &.{ cfg.log_dir, "zmx.log" });
    defer alloc.free(log_path);
    try log_system.init(alloc, log_path, cfg.log_mode);
    defer log_system.deinit();

    const raw = args.next() orelse "list";
    const cmd = Command.fromName(raw) orelse return cmdHelp(alloc, &cfg, &args);
    switch (cmd) {
        .attach => try cmdAttach(alloc, &cfg, &args),
        .run => try cmdRun(alloc, &cfg, &args),
        .send => try cmdSend(alloc, &cfg, &args),
        .print => try cmdPrint(alloc, &cfg, &args),
        .write => try cmdWrite(alloc, &cfg, &args),
        .detach => try cmdDetach(alloc, &cfg, &args),
        .list => try cmdList(alloc, &cfg, &args),
        .kill => try cmdKill(alloc, &cfg, &args),
        .history => try cmdHistory(alloc, &cfg, &args),
        .wait => try cmdWait(alloc, &cfg, &args),
        .tail => try cmdTail(alloc, &cfg, &args),
        .completions => try cmdCompletions(alloc, &cfg, &args),
        .version => try cmdVersion(alloc, &cfg, &args),
        .help => try cmdHelp(alloc, &cfg, &args),
    }
}

/// Client represents each terminal that has connected to a session.
///
/// Multiple Clients can connect to a single session.
const Client = struct {
    alloc: std.mem.Allocator,
    socket_fd: i32,
    has_pending_output: bool = false,
    read_buf: ipc.SocketBuffer,
    write_buf: std.ArrayList(u8),

    pub fn deinit(self: *Client) void {
        posix.close(self.socket_fd);
        self.read_buf.deinit();
        self.write_buf.deinit(self.alloc);
    }
};

/// Cfg is zmx's configuration container.
///
/// The purpose of this container is to hold anything that can be modified by the user.
const Cfg = struct {
    socket_dir: []const u8,
    log_dir: []const u8,
    max_scrollback: usize = 10_000_000,
    dir_mode: u32 = 0o750,
    log_mode: u32 = 0o640,

    pub fn init(alloc: std.mem.Allocator) !Cfg {
        const socket_dir = try socketDir(alloc);
        const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{socket_dir});
        errdefer alloc.free(log_dir);

        const dir_mode = if (std.posix.getenv("ZMX_DIR_MODE")) |m|
            std.fmt.parseInt(u32, m, 8) catch 0o750
        else
            0o750;

        const log_mode = if (std.posix.getenv("ZMX_LOG_MODE")) |m|
            std.fmt.parseInt(u32, m, 8) catch 0o640
        else
            0o640;

        var cfg = Cfg{
            .socket_dir = socket_dir,
            .log_dir = log_dir,
            .dir_mode = dir_mode,
            .log_mode = log_mode,
        };

        try cfg.mkdir();

        return cfg;
    }

    fn socketDir(alloc: std.mem.Allocator) ![]const u8 {
        const tmpdir = std.mem.trimRight(u8, posix.getenv("TMPDIR") orelse "/tmp", "/");
        const uid = posix.getuid();

        const socket_dir: []const u8 = if (posix.getenv("ZMX_DIR")) |zmxdir|
            try alloc.dupe(u8, zmxdir)
        else if (posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime|
            try std.fmt.allocPrint(alloc, "{s}/zmx", .{xdg_runtime})
        else
            try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });
        errdefer alloc.free(socket_dir);

        return socket_dir;
    }

    pub fn deinit(self: *Cfg, alloc: std.mem.Allocator) void {
        if (self.socket_dir.len > 0) alloc.free(self.socket_dir);
        if (self.log_dir.len > 0) alloc.free(self.log_dir);
    }

    pub fn mkdir(self: *Cfg) !void {
        posix.mkdirat(
            posix.AT.FDCWD,
            self.socket_dir,
            @intCast(self.dir_mode),
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        posix.mkdirat(
            posix.AT.FDCWD,
            self.log_dir,
            @intCast(self.dir_mode),
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
};

test "Cfg.init uses default modes when env vars are not set" {
    const alloc = std.testing.allocator;

    // Ensure they are not set
    _ = cross.c.unsetenv("ZMX_DIR_MODE");
    _ = cross.c.unsetenv("ZMX_LOG_MODE");

    var cfg = try Cfg.init(alloc);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o750), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o640), cfg.log_mode);
}

test "Cfg.init uses custom modes from env vars" {
    const alloc = std.testing.allocator;

    // Set custom octal values
    _ = cross.c.setenv("ZMX_DIR_MODE", "770", 1);
    _ = cross.c.setenv("ZMX_LOG_MODE", "660", 1);
    defer {
        _ = cross.c.unsetenv("ZMX_DIR_MODE");
        _ = cross.c.unsetenv("ZMX_LOG_MODE");
    }

    var cfg = try Cfg.init(alloc);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o770), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o660), cfg.log_mode);
}

/// Daemon is responsible for managing a zmx session.
///
/// It holds all the state for a running session.  Instead of a single daemon for all sessions, we
/// create a daemon for every session.  This has some benefits. The ipc communication between
/// session clients and the daemon doesn't need to be tagged with the session name.  If a daemon
/// crashes for one session won't crash all the other sessions.
///
/// Conceptually it's also much simpler to reason about.
const Daemon = struct {
    cfg: *Cfg,
    alloc: std.mem.Allocator,
    clients: std.ArrayList(*Client),
    // This control which client is the leader.  The leader controls terminal state and
    // cols/rows of session.
    leader_client_fd: ?i32,
    session_name: []const u8,
    socket_path: []const u8,
    running: bool,
    pid: i32,
    command: ?[]const []const u8 = null,
    cwd: []const u8 = "",
    has_pty_output: bool = false,
    has_had_client: bool = false,
    has_terminal_client: bool = false, // true only after a real attach (.Init received)
    created_at: u64, // unix timestamp (ns)
    is_task_mode: bool = false, // flag for when session is run as a task
    task_exit_code: ?u8 = null, // null = running or n/a, set when task completes
    task_ended_at: ?u64 = null, // timestamp when task exited
    pty_fd: i32 = -1, // set by daemonLoop so handleRun can probe the foreground process
    pty_write_buf: std.ArrayList(u8) = .empty,

    const PTY_WRITE_BUF_MAX = 256 * 1024;

    const EnsureSessionResult = struct {
        created: bool,
        is_daemon: bool,
    };

    pub fn deinit(self: *Daemon) void {
        self.clients.deinit(self.alloc);
        self.pty_write_buf.deinit(self.alloc);
        self.alloc.free(self.socket_path);
    }

    pub fn shutdown(self: *Daemon) void {
        std.log.info("shutting down daemon session={s}", .{self.session_name});
        self.running = false;

        for (self.clients.items) |client| {
            client.deinit();
            self.alloc.destroy(client);
        }
        self.clients.clearRetainingCapacity();
    }

    pub fn closeClient(self: *Daemon, client: *Client, i: usize, shutdown_on_last: bool) bool {
        const fd = client.socket_fd;
        // leader is disconnected, remove ref and let another client claim leader on input
        if (self.leader_client_fd == client.socket_fd) {
            std.log.info(
                "unsetting leader session={s} fd={d}",
                .{ self.session_name, client.socket_fd },
            );
            self.leader_client_fd = null;
        }
        client.deinit();
        self.alloc.destroy(client);
        _ = self.clients.orderedRemove(i);
        std.log.info("client disconnected fd={d} remaining={d}", .{ fd, self.clients.items.len });
        if (shutdown_on_last and self.clients.items.len == 0) {
            self.shutdown();
            return true;
        }
        return false;
    }

    fn setLeader(self: *Daemon, client: *Client) !void {
        std.log.info("setting new leader client_fd={d}", .{client.socket_fd});
        self.leader_client_fd = client.socket_fd;
        // Send a resize message to the client so it can send us back their window size
        // so we can resize the pty and ghostty state.
        try ipc.appendMessage(self.alloc, &client.write_buf, .Resize, "");
        client.has_pending_output = true;
    }

    /// Runs in the forked child. Either execs or returns an error (caller
    /// must exit on error -- returning would fall through to parent code).
    fn execChild(self: *Daemon) !noreturn {
        const alloc = std.heap.c_allocator;

        // main() set SIGPIPE to SIG_IGN, which (unlike handlers) survives
        // exec. Restore the default so the shell and its children behave
        // normally (e.g. `yes | head` should exit 141 via SIGPIPE).
        const dfl: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.PIPE, &dfl, null);

        const session_env = try std.fmt.allocPrintSentinel(
            alloc,
            "ZMX_SESSION={s}",
            .{self.session_name},
            0,
        );
        _ = cross.c.putenv(session_env.ptr);

        if (self.command) |cmd_args| {
            const argv = try alloc.allocSentinel(?[*:0]const u8, cmd_args.len, null);
            for (cmd_args, 0..) |arg, i| {
                argv[i] = try alloc.dupeZ(u8, arg);
            }
            const err = std.posix.execvpeZ(argv[0].?, argv.ptr, std.c.environ);
            std.log.err("execvpe failed: cmd={s} err={s}", .{ cmd_args[0], @errorName(err) });
            std.posix.exit(1);
        }

        const shell: [:0]const u8 = if (self.is_task_mode) "bash" else util.detectShell();
        // Use "-shellname" as argv[0] to signal login shell (traditional method)
        const login_shell = try std.fmt.allocPrintSentinel(
            alloc,
            "-{s}",
            .{std.fs.path.basename(shell)},
            0,
        );
        const argv = [_:null]?[*:0]const u8{ login_shell, null };
        const err = std.posix.execvpeZ(shell, &argv, std.c.environ);
        std.log.err("execvpe failed: shell={s} err={s}", .{ shell, @errorName(err) });
        std.posix.exit(1);
    }

    /// spawnPty runs forkpty() and executes the shell or shell command the user provides.
    fn spawnPty(self: *Daemon) !c_int {
        const size = ipc.getTerminalSize(posix.STDOUT_FILENO);
        var ws: cross.c.struct_winsize = .{
            .ws_row = size.rows,
            .ws_col = size.cols,
            .ws_xpixel = size.xpixel,
            .ws_ypixel = size.ypixel,
        };

        var master_fd: c_int = undefined;
        const pid = cross.forkpty(&master_fd, null, null, &ws);
        if (pid < 0) {
            return error.ForkPtyFailed;
        }

        if (pid == 0) { // child pid code path
            // In the forked child, ANY error must exit rather than propagate:
            // a returned error falls through to the parent code path below,
            // running a second daemon on the same socket (or worse, hitting
            // errdefers that delete the parent's socket file).
            execChild(self) catch |err| {
                std.log.err("child setup failed: {s}", .{@errorName(err)});
                std.posix.exit(1);
            };
            unreachable; // execChild either execs or exits, never returns ok
        }
        // master pid code path
        self.pid = pid;
        std.log.info("pty spawned session={s} pid={d}", .{ self.session_name, pid });

        // make pty non-blocking
        const flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(master_fd, posix.F.SETFL, flags | O_NONBLOCK);
        return master_fd;
    }

    fn isSessionAvailable(self: *Daemon, dir: std.fs.Dir) bool {
        if (ipc.connectSession(self.socket_path)) |fd| {
            posix.close(fd);
            if (self.command != null) {
                std.log.warn(
                    "session already exists, ignoring command session={s}",
                    .{self.session_name},
                );
            }
        } else |err| switch (err) {
            // Daemon is definitively gone: safe to replace.
            error.ConnectionRefused => {
                socket.cleanupStaleSocket(dir, self.session_name);
                return false;
            },
            // Connect failed for an unusual reason. The check is only to
            // decide create-vs-attach; the socket file exists, so proceed
            // to attach rather than fail or orphan.
            else => {
                std.log.warn(
                    "connect failed ({s}), proceeding to attach session={s}",
                    .{ @errorName(err), self.session_name },
                );
            },
        }

        return true;
    }

    fn createNewSession(self: *Daemon, dir: std.fs.Dir) !EnsureSessionResult {
        std.log.info("creating session={s}", .{self.session_name});
        const server_sock_fd = try socket.createSocket(self.socket_path);

        // creates the daemon
        const pid = try posix.fork();
        if (pid == 0) {
            // child (daemon)
            // becomes the session leader and detaches process from its controlling terminal
            _ = try posix.setsid();

            log_system.deinit();

            // Redirect stdin/stdout/stderr to /dev/null. The daemon
            // communicates via its unix socket, not stdio. Without
            // this, any pipe on FDs 0-2 (e.g. from bats' `run`
            // keyword) stays open for the daemon's lifetime, causing
            // the caller to hang waiting for EOF.
            {
                const devnull = std.posix.open(
                    "/dev/null",
                    .{ .ACCMODE = .RDWR },
                    0,
                ) catch |err| {
                    std.log.warn("failed to open /dev/null: {s}", .{@errorName(err)});
                    return err;
                };
                inline for (.{ posix.STDIN_FILENO, posix.STDOUT_FILENO, posix.STDERR_FILENO }) |fd| {
                    _ = posix.dup2(devnull, fd) catch |err| {
                        std.log.warn("dup2 /dev/null -> {d}: {s}", .{ fd, @errorName(err) });
                        return err;
                    };
                }
                if (devnull > 2) posix.close(devnull);
            }

            // Close file descriptors inherited from the parent that the
            // daemon doesn't need. This prevents test harnesses (like
            // bats) from hanging -- they wait for their internal FDs (3+)
            // to close before exiting.
            //
            // Must run BEFORE log_system.init() otherwise the new log
            // FD gets closed, and spawnPty() reuses that FD number for
            // the PTY master, causing log writes to leak into the terminal.
            //
            // Skip server_sock_fd (needed for IPC) and dir.fd (needed to
            // delete the socket file on shutdown).
            {
                const dir_fd = @as(i32, @intCast(dir.fd));
                var fd: i32 = 3;
                while (fd < 64) : (fd += 1) {
                    if (fd == server_sock_fd or fd == dir_fd) continue;
                    _ = std.c.close(fd);
                }
            }

            const session_log_name = try std.fmt.allocPrint(
                self.alloc,
                "{s}.log",
                .{self.session_name},
            );
            defer self.alloc.free(session_log_name);
            const session_log_path = try std.fs.path.join(
                self.alloc,
                &.{ self.cfg.log_dir, session_log_name },
            );
            defer self.alloc.free(session_log_path);
            try log_system.init(self.alloc, session_log_path, self.cfg.log_mode);

            // If spawnPty fails, clean up here. Once it succeeds,
            // the inner block's defer takes ownership of cleanup to
            // avoid double-closing server_sock_fd on daemonLoop error.
            const pty_fd = self.spawnPty() catch |err| {
                posix.close(server_sock_fd);
                dir.deleteFile(self.session_name) catch {};
                return err;
            };

            defer {
                self.handleKill();
                self.deinit();
                posix.close(pty_fd);
                _ = posix.waitpid(self.pid, 0);
                posix.close(server_sock_fd);
                std.log.info("deleting socket file session={s}", .{self.session_name});
                dir.deleteFile(self.session_name) catch |err| {
                    std.log.warn("failed to delete socket file err={s}", .{@errorName(err)});
                };
            }

            try daemonLoop(self, server_sock_fd, pty_fd);
            return .{ .created = true, .is_daemon = true };
        }
        posix.close(server_sock_fd);
        std.Thread.sleep(10 * std.time.ns_per_ms);
        return .{ .created = true, .is_daemon = false };
    }

    /// ensureSession "upserts" a session by checking if the unix socket exists already.
    /// If not it creates one and spawns the daemon.
    fn ensureSession(self: *Daemon) !EnsureSessionResult {
        var dir = try std.fs.openDirAbsolute(self.cfg.socket_dir, .{});
        defer dir.close();

        const exists = try socket.sessionExists(dir, self.session_name);
        const should_create = !(exists and self.isSessionAvailable(dir));

        if (should_create) {
            return self.createNewSession(dir);
        }

        return .{ .created = false, .is_daemon = false };
    }

    /// Queue bytes for the PTY's stdin. Flushed by daemonLoop on POLLOUT.
    /// Drops the payload if the buffer is over cap -- same failure mode as
    /// the old direct-write ptyWrite (drop on EAGAIN), just at a 64x higher
    /// threshold. Capping avoids OOM when the shell stops reading; dropping
    /// new (not old) bytes avoids tearing a partially-accepted sequence.
    fn queuePtyInput(self: *Daemon, data: []const u8) void {
        if (data.len == 0) return;
        if (self.pty_write_buf.items.len + data.len > PTY_WRITE_BUF_MAX) {
            std.log.warn(
                "pty input dropped {d} bytes (buffer full, shell not reading)",
                .{data.len},
            );
            return;
        }
        std.log.debug("buffering pty input data={x}", .{data});
        self.pty_write_buf.appendSlice(self.alloc, data) catch |err| {
            std.log.warn(
                "pty input dropped {d} bytes: {s}",
                .{ data.len, @errorName(err) },
            );
        };
    }

    pub fn handleInput(self: *Daemon, client: *Client, payload: []const u8) !void {
        std.log.debug("buffering pty input data={x}", .{payload});
        // client is leader, send entire payload (ansi escape codes + text)
        if (self.leader_client_fd == client.socket_fd) {
            self.queuePtyInput(payload);
            return;
        }

        // check if leader needs to be updated by detecting any user input
        if (util.isUserInput(payload)) {
            try self.setLeader(client);
            self.queuePtyInput(payload);
        }
    }

    pub fn handleSwitch(self: *Daemon, session_name: []const u8) !void {
        for (self.clients.items) |client| {
            if (self.leader_client_fd != client.socket_fd) {
                continue;
            }
            ipc.appendMessage(
                self.alloc,
                &client.write_buf,
                .Switch,
                session_name,
            ) catch |err| {
                std.log.warn(
                    "failed to buffer terminal state for client err={s}",
                    .{@errorName(err)},
                );
            };
            client.has_pending_output = true;
            return;
        }
        return error.NoLeaderFound;
    }

    pub fn handleInit(
        self: *Daemon,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;

        // Serialize terminal state BEFORE resize to capture correct cursor position.
        // Resizing triggers reflow which can move the cursor, and the shell's
        // SIGWINCH-triggered redraw will run after our snapshot is sent.
        // Only serialize on re-attach (has_had_client), not first attach, to avoid
        // interfering with shell initialization (DA1 queries, etc.)
        if (self.has_pty_output and self.has_had_client) {
            const cursor = &term.screens.active.cursor;
            std.log.debug(
                "cursor before serialize: x={d} y={d} pending_wrap={}",
                .{ cursor.x, cursor.y, cursor.pending_wrap },
            );
            if (util.serializeTerminalState(self.alloc, term)) |term_output| {
                std.log.debug("serialize terminal state", .{});
                // Rewrite OSC 133;A to include redraw=0 so the outer terminal
                // does not clear prompt lines on resize (issue #111).
                const restore_data = util.rewritePromptRedraw(self.alloc, term_output) orelse term_output;
                defer self.alloc.free(term_output);
                defer if (restore_data.ptr != term_output.ptr) self.alloc.free(restore_data);
                ipc.appendMessage(self.alloc, &client.write_buf, .Output, restore_data) catch |err| {
                    std.log.warn(
                        "failed to buffer terminal state for client err={s}",
                        .{@errorName(err)},
                    );
                };
                client.has_pending_output = true;
            }
        }

        // no leader is set so set one
        if (self.leader_client_fd == null) {
            try self.setLeader(client);
        }

        // only resize if leader
        if (self.leader_client_fd == client.socket_fd) {
            const resize = std.mem.bytesToValue(ipc.Resize, payload);
            var ws: cross.c.struct_winsize = .{
                .ws_row = resize.rows,
                .ws_col = resize.cols,
                .ws_xpixel = resize.xpixel,
                .ws_ypixel = resize.ypixel,
            };
            _ = cross.c.ioctl(pty_fd, cross.c.TIOCSWINSZ, &ws);
            // Disable prompt_redraw before resize. The daemon's internal terminal
            // would otherwise clear prompt lines expecting the shell to redraw them,
            // but the shell's redraw goes to the PTY (forwarded to clients), not to
            // this daemon terminal. The clearing corrupts the daemon's snapshot state.
            const saved_prompt_redraw = term.flags.shell_redraws_prompt;
            term.flags.shell_redraws_prompt = .false;
            defer term.flags.shell_redraws_prompt = saved_prompt_redraw;
            try term.resize(self.alloc, resize.cols, resize.rows);

            // Mark that we've had a client init, so subsequent clients get terminal state
            self.has_had_client = true;
            self.has_terminal_client = true;

            std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });
        }
    }

    pub fn handleResize(
        self: *Daemon,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;
        if (self.leader_client_fd == null) {
            try self.setLeader(client);
        }
        // only leader can resize
        if (self.leader_client_fd != client.socket_fd) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        var ws: cross.c.struct_winsize = .{
            .ws_row = resize.rows,
            .ws_col = resize.cols,
            .ws_xpixel = resize.xpixel,
            .ws_ypixel = resize.ypixel,
        };
        _ = cross.c.ioctl(pty_fd, cross.c.TIOCSWINSZ, &ws);
        // Disable prompt_redraw before resize (same rationale as handleInit).
        const saved_prompt_redraw = term.flags.shell_redraws_prompt;
        term.flags.shell_redraws_prompt = .false;
        defer term.flags.shell_redraws_prompt = saved_prompt_redraw;
        try term.resize(self.alloc, resize.cols, resize.rows);
        std.log.debug("resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleDetach(self: *Daemon, client: *Client, i: usize) void {
        std.log.info("client detach session={s} fd={d}", .{ self.session_name, client.socket_fd });
        _ = self.closeClient(client, i, false);
    }

    pub fn handleDetachAll(self: *Daemon) void {
        std.log.info("detach all clients={d}", .{self.clients.items.len});
        for (self.clients.items) |client_to_close| {
            client_to_close.deinit();
            self.alloc.destroy(client_to_close);
        }
        self.clients.clearRetainingCapacity();
    }

    pub fn handleKill(self: *Daemon) void {
        std.log.info("kill received session={s}", .{self.session_name});
        self.shutdown();
        // gracefully shutdown shell processes, shells tend to ignore SIGTERM so we send SIGHUP
        // instead
        //   https://www.gnu.org/software/bash/manual/html_node/Signals.html
        // negative pid means kill process and children
        std.log.info("sending SIGHUP session={s} pid={d}", .{ self.session_name, self.pid });
        posix.kill(-self.pid, posix.SIG.HUP) catch |err| {
            std.log.warn("failed to send SIGHUP to pty child err={s}", .{@errorName(err)});
        };
        std.Thread.sleep(500 * std.time.ns_per_ms);
        posix.kill(-self.pid, posix.SIG.KILL) catch |err| {
            std.log.warn("failed to send SIGKILL to pty child err={s}", .{@errorName(err)});
        };
    }

    pub fn handleInfo(self: *Daemon, client: *Client) !void {
        // zeroes() so asBytes() doesn't ship struct padding + unused cmd/cwd
        // tail bytes (daemon stack contents) to clients.
        var info = std.mem.zeroes(ipc.Info);
        info.clients_len = self.clients.items.len - 1;
        info.pid = self.pid;
        info.created_at = self.created_at;
        info.task_ended_at = self.task_ended_at orelse 0;
        info.task_exit_code = self.task_exit_code orelse 0;

        // Build command string from args, re-quoting args that contain
        // shell-special characters so the displayed command is copy-pasteable.
        const cur_cmd = self.command;
        if (cur_cmd) |args| {
            for (args, 0..) |arg, i| {
                const quoted = if (util.shellNeedsQuoting(arg))
                    util.shellQuote(self.alloc, arg) catch null
                else
                    null;
                defer if (quoted) |q| self.alloc.free(q);
                const src = quoted orelse arg;

                const need = src.len + @as(usize, if (i > 0) 1 else 0);
                if (info.cmd_len + need > ipc.MAX_CMD_LEN) {
                    const ellipsis = "...";
                    if (info.cmd_len + ellipsis.len <= ipc.MAX_CMD_LEN) {
                        @memcpy(info.cmd[info.cmd_len..][0..ellipsis.len], ellipsis);
                        info.cmd_len += ellipsis.len;
                    }
                    break;
                }

                if (i > 0) {
                    info.cmd[info.cmd_len] = ' ';
                    info.cmd_len += 1;
                }
                @memcpy(info.cmd[info.cmd_len..][0..src.len], src);
                info.cmd_len += @intCast(src.len);
            }
        }

        info.cwd_len = @intCast(@min(self.cwd.len, ipc.MAX_CWD_LEN));
        @memcpy(info.cwd[0..info.cwd_len], self.cwd[0..info.cwd_len]);

        try ipc.appendMessage(self.alloc, &client.write_buf, .Info, std.mem.asBytes(&info));
        client.has_pending_output = true;
    }

    pub fn handleHistory(
        self: *Daemon,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        const format: util.HistoryFormat = if (payload.len > 0)
            std.meta.intToEnum(util.HistoryFormat, payload[0]) catch .plain
        else
            .plain;
        if (util.serializeTerminal(self.alloc, term, format)) |output| {
            defer self.alloc.free(output);
            try ipc.appendMessage(self.alloc, &client.write_buf, .History, output);
            client.has_pending_output = true;
        } else {
            try ipc.appendMessage(self.alloc, &client.write_buf, .History, "");
            client.has_pending_output = true;
        }
    }

    pub fn handleRun(self: *Daemon, client: *Client, payload: []const u8) !void {
        // Reset task tracking so the new command's exit marker is detected.
        // Without this, a second `zmx run` on the same session is ignored
        // because task_exit_code is still set from the first run.
        self.task_exit_code = null;
        self.task_ended_at = null;
        self.is_task_mode = true;

        if (payload.len == 0) return;

        const cmd = payload;

        // Chain the exit marker with `;` on the same line. `$?` captures the
        // exit code of the command (not the `;`). The sole exception is when
        // the command contains a heredoc (`<<`), the delimiter must be alone
        // on its line, so the marker goes on the next line instead.
        const single_line_marker = "; echo ZMX_TASK_COMPLETED:$?\r";
        const heredoc_marker = "\r\necho ZMX_TASK_COMPLETED:$?\r";
        const uses_heredoc = std.mem.indexOf(u8, cmd, "<<") != null;

        if (cmd.len > 0 and cmd[cmd.len - 1] == '\r') {
            self.queuePtyInput(cmd[0 .. cmd.len - 1]);
        } else {
            self.queuePtyInput(cmd);
        }
        self.queuePtyInput(if (uses_heredoc) heredoc_marker else single_line_marker);

        try ipc.appendMessage(self.alloc, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        self.has_had_client = true;
        std.log.debug("run command len={d}", .{payload.len});
    }

    pub fn handleOutput(self: *Daemon, payload: []const u8, vt_stream: anytype) !void {
        vt_stream.nextSlice(payload);
        self.has_pty_output = true;
        for (self.clients.items) |client| {
            try ipc.appendMessage(self.alloc, &client.write_buf, .Output, payload);
            client.has_pending_output = true;
        }
        if (self.clients.items.len > 0) {
            posix.kill(self.pid, posix.SIG.WINCH) catch |err| {
                std.log.warn("failed to send SIGWINCH err={s}", .{@errorName(err)});
            };
        }
    }

    pub fn handleWrite(self: *Daemon, client: *Client, payload: []const u8) !void {
        // Wire format: [u32 path len][path bytes][file content]
        if (payload.len < @sizeOf(u32)) return error.InvalidPayload;
        const path_len = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]);
        if (payload.len < @sizeOf(u32) + path_len) return error.InvalidPayload;
        const file_path = payload[@sizeOf(u32)..][0..path_len];
        const file_content = payload[@sizeOf(u32) + path_len ..];

        // Inject file creation through the PTY so it works over SSH.
        // Base64-encode content and pipe through printf | base64 -d > file.
        // Chunk large files to stay under command-line length limits.
        // 48000 is divisible by 3 (clean base64 boundaries) and encodes
        // to ~64KB, well under typical ARG_MAX.
        const chunk_size = 48000;
        var offset: usize = 0;
        var is_first = true;

        while (offset < file_content.len or is_first) {
            const end = @min(offset + chunk_size, file_content.len);
            const chunk = file_content[offset..end];

            const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
            const encoded = try self.alloc.alloc(u8, encoded_len);
            defer self.alloc.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, chunk);

            self.queuePtyInput("printf '%s' '");
            self.queuePtyInput(encoded);
            if (is_first) {
                self.queuePtyInput("' | base64 -d > '");
            } else {
                self.queuePtyInput("' | base64 -d >> '");
            }
            self.queuePtyInput(file_path);
            self.queuePtyInput("'");
            self.queuePtyInput("\r");

            offset = end;
            is_first = false;
        }

        try ipc.appendMessage(self.alloc, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        self.has_had_client = true;
        std.log.debug(
            "write command len={d} file_path={s}",
            .{ file_content.len, file_path },
        );
    }
};

fn printCompletions(shell: completions.Shell) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.writeAll(switch (shell) {
        .bash => completions.bashScript(ALL_COMMANDS),
        .zsh => completions.zshScript(ALL_COMMANDS),
        .fish => completions.fishScript(ALL_COMMANDS),
        .nu => completions.nuScript(ALL_COMMANDS),
    });
    try w.interface.flush();
}

fn help() !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("zmx - session persistence for terminal processes\n\nUsage: zmx <command> [args...]\n\nCommands:\n", .{});
    for (ALL_COMMANDS) |m| {
        const display_name = if (std.mem.startsWith(u8, m.name, m.aliases[0])) m.name[m.aliases[0].len..] else m.name;
        try w.interface.print("  [{s}]{s}", .{ m.aliases[0], display_name });
        for (m.aliases[1..]) |alias| {
            if (std.mem.startsWith(u8, alias, "-")) continue;
            try w.interface.print("|{s}", .{alias});
        }
        try w.interface.print("  {s}\n", .{m.help_line});
    }
    try w.interface.print(
        \\Environment variables:
        \\  SHELL                Default shell for new sessions
        \\  ZMX_DIR              Socket directory (priority 1)
        \\  XDG_RUNTIME_DIR      Socket directory (priority 2)
        \\  TMPDIR               Socket directory (priority 3)
        \\  ZMX_SESSION          Session name (injected automatically)
        \\  ZMX_SESSION_PREFIX   Prefix added to all session names
        \\  ZMX_DIR_MODE         Sets mode for socket and log directories (octal, defaults to 0750)
        \\  ZMX_LOG_MODE         Sets mode for log files (octal, defaults to 0640)
    , .{});
    try w.interface.flush();
}

fn buildPollList(
    alloc: std.mem.Allocator,
    poll_fds: *std.ArrayList(posix.pollfd),
    client_fds: []const i32,
    has_pending_stdout: bool,
) !void {
    for (client_fds) |fd| {
        try poll_fds.append(alloc, .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 });
    }
    if (has_pending_stdout) {
        try poll_fds.append(alloc, .{ .fd = posix.STDOUT_FILENO, .events = posix.POLL.OUT, .revents = 0 });
    }
}

fn processDaemonMessages(
    read_buf: *ipc.SocketBuffer,
    alloc: std.mem.Allocator,
    stdout_buf: *std.ArrayList(u8),
    is_first_line: *bool,
    task_complete_code: *?u8,
    detached: bool,
    is_run_cmd: bool,
) !?u8 {
    while (read_buf.next()) |msg| {
        switch (msg.header.tag) {
            .Ack => {
                if (!detached) continue;
                _ = posix.write(posix.STDOUT_FILENO, "command sent!\n") catch |err| {
                    if (err == error.WouldBlock) return 0;
                    return err;
                };
                return 0;
            },
            .Output => {
                if (msg.payload.len == 0) continue;
                var payload = msg.payload;
                if (!detached and is_run_cmd and is_first_line.*) {
                    is_first_line.* = false;
                    payload = if (std.mem.indexOfScalar(u8, payload, '\n')) |nl|
                        payload[nl + 1 ..]
                    else
                        payload[payload.len..];
                }
                if (payload.len == 0) continue;
                const plain = util.stripAnsi(alloc, payload) catch |err| {
                    std.log.warn("stripAnsi failed: {s}", .{@errorName(err)});
                    continue;
                };
                defer alloc.free(plain);
                if (plain.len == 0) continue;
                try stdout_buf.appendSlice(alloc, plain);
            },
            .TaskComplete => {
                task_complete_code.* = if (msg.payload.len > 0) msg.payload[0] else 0;
            },
            else => {},
        }
    }
    return null;
}

fn tail(client_socket_fds: std.ArrayList(i32), detached: bool, is_run_cmd: bool) !u8 {
    std.debug.assert(client_socket_fds.items.len > 0);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(alloc, 4);
    defer poll_fds.deinit(alloc);

    var read_buf = try ipc.SocketBuffer.init(alloc);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer stdout_buf.deinit(alloc);

    var is_first_line = true;
    var task_complete_code: ?u8 = null;

    while (true) {
        poll_fds.clearRetainingCapacity();
        std.debug.assert(poll_fds.items.len == 0);

        try buildPollList(alloc, &poll_fds, client_socket_fds.items, stdout_buf.items.len > 0);

        _ = posix.poll(poll_fds.items, -1) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };

        for (poll_fds.items) |*poll_fd| {
            if (poll_fd.revents & posix.POLL.IN == 0) continue;

            const n = read_buf.read(poll_fd.fd) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) return 1;
                std.log.err("daemon read err={s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) return 0;

            const exit_code = try processDaemonMessages(
                &read_buf,
                alloc,
                &stdout_buf,
                &is_first_line,
                &task_complete_code,
                detached,
                is_run_cmd,
            );
            if (exit_code) |code| return code;
        }

        if (stdout_buf.items.len > 0) {
            const n = posix.write(posix.STDOUT_FILENO, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (task_complete_code) |code| return code;
            if (n > 0) try stdout_buf.replaceRange(alloc, 0, n, &[_]u8{});
        }

        for (poll_fds.items) |poll_fd| {
            if (poll_fd.revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) return 0;
        }
    }
}

fn wait(cfg: *Cfg, matchers: std.ArrayList(SessionMatch)) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Highest match count seen so far. Lets us distinguish "sessions haven't
    // appeared yet" (keep polling) from "sessions we were tracking
    // disappeared" (fail -- daemon crashed or was killed).
    var max_seen: i32 = 0;
    var zero_match_iters: u32 = 0;

    var agg_exit_code: u8 = 0;
    var last_print: i64 = 0;
    var prev_done: i32 = 0;
    while (true) {
        agg_exit_code = 0;
        var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
        var total: i32 = 0;
        var done: i32 = 0;

        for (sessions.items) |session| {
            var found = false;
            for (matchers.items) |m| {
                if (m.matches(session.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                continue;
            }

            total += 1;
            if (session.is_error) {
                // Daemon unreachable (probe timed out). On Timeout the socket
                // is no longer deleted, so this session would otherwise
                // persist as task_ended_at==0 forever → infinite "still
                // waiting". Count it as done+failed so wait terminates.
                try stderr.print(
                    "[{d}] task unreachable: {s} ({s})\n",
                    .{ std.time.timestamp(), session.name, session.error_name orelse "unknown" },
                );
                try stderr.flush();
                agg_exit_code = 1;
                done += 1;
                continue;
            }
            if (session.task_ended_at == 0) {
                const now = std.time.timestamp();
                if (now - last_print >= 5) {
                    try stdout.print(
                        "[{d}] waiting task={s}\n",
                        .{ now, session.name },
                    );
                    try stdout.flush();
                    last_print = now;
                }
                continue;
            }
            if (done >= prev_done) {
                // Newly completed — print immediately
                try stdout.print(
                    "[{d}] completed task={s} exit_code={d}\n",
                    .{ session.task_ended_at.?, session.name, session.task_exit_code.? },
                );
                try stdout.flush();
            }
            if (session.task_exit_code != 0) {
                agg_exit_code = session.task_exit_code orelse 0;
            }
            done += 1;
        }

        for (sessions.items) |session| {
            session.deinit(alloc);
        }
        sessions.deinit(alloc);

        // Check disappearance BEFORE completion: if one of N sessions
        // crashed and the remaining N-1 happen to be done, total==done
        // would be a false success.
        if (total < max_seen) {
            try stderr.print(
                "error: {d} session(s) disappeared before completing\n",
                .{max_seen - total},
            );
            try stderr.flush();
            std.process.exit(1);
            return;
        }
        max_seen = total;

        if (total > 0 and total == done) {
            break;
        }

        if (max_seen == 0) {
            // `zmx run foo && zmx wait foo` is essentially sequential, so
            // matching sessions should be visible from the first poll. If
            // nothing appears after a few iterations it's almost certainly a
            // typo, not a slow start.
            zero_match_iters += 1;
            if (zero_match_iters >= 3) {
                try stderr.print("error: no matching sessions found\n", .{});
                try stderr.flush();
                std.process.exit(2);
                return;
            }
        }

        prev_done = done;
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }

    if (agg_exit_code == 0) {
        try stdout.print("task(s) completed!\n", .{});
    } else {
        try stdout.print("task(s) failed!\n", .{});
    }
    try stdout.flush();

    const sessions = try util.get_session_entries(alloc, cfg.socket_dir);
    for (sessions.items) |session| {
        var found = false;
        for (matchers.items) |m| {
            if (m.matches(session.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            continue;
        }
        if (session.task_exit_code.? > 0) {
            try stdout.print("---\n", .{});
            try stdout.print("[{d}] failed task={s} exit_status={d}\n", .{
                session.task_ended_at.?,
                session.name,
                session.task_exit_code.?,
            });

            // Fetch and print the last 20 lines of history for debugging
            const history_lines: usize = 20;
            const history_text = fetchHistory(alloc, cfg, session.name) catch null;
            if (history_text) |text| {
                defer alloc.free(text);
                try stdout.print("\nLast {d} lines of {s} history:\n", .{ history_lines, session.name });

                // Count lines and find the start of the last N lines
                var total_lines: usize = 0;
                var it = std.mem.splitScalar(u8, text, '\n');
                while (it.next()) |_| {
                    total_lines += 1;
                }

                const skip = if (total_lines > history_lines) total_lines - history_lines else 0;
                var current: usize = 0;
                it = std.mem.splitScalar(u8, text, '\n');
                while (it.next()) |line| {
                    if (current >= skip) {
                        try stdout.print("{s}\n", .{line});
                    }
                    current += 1;
                }
            }

            try stdout.print("\nSee the logs:\nzmx history {s}\nzmx attach {s}\n", .{ session.name, session.name });
            try stdout.flush();
        }
    }

    std.process.exit(agg_exit_code);
}

fn list(cfg: *Cfg, short: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const current_session = socket.getSeshNameFromEnv();
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
    defer {
        for (sessions.items) |session| {
            session.deinit(alloc);
        }
        sessions.deinit(alloc);
    }

    if (sessions.items.len == 0) {
        if (short) return;
        var errbuf: [4096]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&errbuf);
        try stderr.interface.print("no sessions found in {s}\n", .{cfg.socket_dir});
        try stderr.interface.flush();
        return;
    }

    std.mem.sort(util.SessionEntry, sessions.items, {}, util.SessionEntry.lessThan);

    for (sessions.items) |session| {
        try util.writeSessionLine(&stdout.interface, session, short, current_session);
        try stdout.interface.flush();
    }
}

fn detachAll(cfg: *Cfg) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const session_name = socket.getSeshNameFromEnv();
    if (session_name.len == 0) {
        std.log.err("ZMX_SESSION env var not found: are you inside a zmx session?", .{});
        return;
    }

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);
    const fd = ipc.connectSession(socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return;
    };
    defer posix.close(fd);
    ipc.send(fd, .DetachAll, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

fn kill(cfg: *Cfg, session_name: []const u8, force: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, session_name);
    if (!exists) {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        w.interface.print("error: session \"{s}\" does not exist\n", .{session_name}) catch {};
        w.interface.flush() catch {};
        return error.SessionNotFound;
    }
    const fd = ipc.connectSession(socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        if (force or err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(dir, session_name);
            w.interface.print("cleaned up stale session {s}\n", .{session_name}) catch {};
        } else {
            w.interface.print(
                "session {s} is unresponsive ({s})\ndaemon may be busy: try again, add `--force` flag, or kill the process directly\n",
                .{ session_name, @errorName(err) },
            ) catch {};
        }
        w.interface.flush() catch {};
        return;
    };

    defer posix.close(fd);
    ipc.send(fd, .Kill, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var buf: [100]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("killed session {s}\n", .{session_name});
    try w.interface.flush();
}

/// Fetch terminal history from a session socket, returning it as an allocated
/// string. Caller owns the returned memory and must free it.
fn fetchHistory(
    alloc: std.mem.Allocator,
    cfg: *Cfg,
    session_name: []const u8,
) ![]const u8 {
    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => {
            socket.printSessionNameTooLong(session_name, cfg.socket_dir);
            return error.NameTooLong;
        },
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, session_name);
    if (!exists) {
        return error.SessionNotFound;
    }

    const fd = ipc.connectSession(socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return err;
    };
    defer posix.close(fd);

    const format_byte: u8 = @intFromEnum(util.HistoryFormat.plain);
    const payload = [_]u8{format_byte};
    ipc.send(fd, .History, &payload) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return error.SessionUnresponsive,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    var result = std.ArrayList(u8).initCapacity(alloc, 4096) catch return error.OutOfMemory;
    errdefer result.deinit(alloc);

    while (true) {
        var poll_fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const poll_result = posix.poll(&poll_fds, 5000) catch return error.Timeout;
        if (poll_result == 0) {
            return error.Timeout;
        }

        const n = sb.read(fd) catch return error.ReadFailed;
        if (n == 0) break;

        while (sb.next()) |msg| {
            if (msg.header.tag == .History) {
                try result.appendSlice(alloc, msg.payload);
                return result.toOwnedSlice(alloc);
            }
        }
    }

    return error.NoHistoryResponse;
}

fn history(cfg: *Cfg, session_name: []const u8, format: util.HistoryFormat) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, session_name);
    if (!exists) {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        w.interface.print("error: session \"{s}\" does not exist\n", .{session_name}) catch {};
        w.interface.flush() catch {};
        return error.SessionNotFound;
    }
    const fd = ipc.connectSession(socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return;
    };
    defer posix.close(fd);

    const format_byte = [_]u8{@intFromEnum(format)};
    ipc.send(fd, .History, &format_byte) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    while (true) {
        var poll_fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const poll_result = posix.poll(&poll_fds, 5000) catch return;
        if (poll_result == 0) {
            std.log.err("timeout waiting for history response", .{});
            return;
        }

        const n = sb.read(fd) catch return;
        if (n == 0) return;

        while (sb.next()) |msg| {
            if (msg.header.tag == .History) {
                _ = posix.write(posix.STDOUT_FILENO, msg.payload) catch return;
                return;
            }
        }
    }
}

fn switchSesh(daemon: *Daemon, current_sesh: []const u8) !void {
    // we want daemon.session_name because that's the session name the user provided during zmx attach
    // instead of the name of the session they are currently inside of.
    const next_session = daemon.session_name;

    const socket_path = socket.getSocketPath(daemon.alloc, daemon.cfg.socket_dir, current_sesh) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(current_sesh, daemon.cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer daemon.alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(daemon.cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, current_sesh);
    if (!exists) {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        w.interface.print("error: session \"{s}\" does not exist\n", .{current_sesh}) catch {};
        w.interface.flush() catch {};
        return error.SessionNotFound;
    }
    const fd = ipc.connectSession(socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, current_sesh);
        return;
    };
    defer posix.close(fd);

    ipc.send(fd, .Switch, next_session) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

fn attach(daemon: *Daemon) !void {
    const sesh = socket.getSeshNameFromEnv();
    if (sesh.len > 0) {
        return switchSesh(daemon, sesh);
    }

    const result = try daemon.ensureSession();
    if (result.is_daemon) return;

    const client_sock = try socket.sessionConnect(daemon.socket_path);
    std.log.info("attached session={s}", .{daemon.session_name});
    //  This is typically used with tcsetattr() to modify terminal settings.
    //      - you first get the current settings with tcgetattr()
    //      - modify the desired attributes in the termios structure
    //      - then apply the changes with tcsetattr().
    //  This prevents unintended side effects by preserving other settings.
    // restore stdin fd to its original state after exiting.
    // Use TCSAFLUSH to discard any unread input, preventing stale input after detach.
    //
    // tcgetattr fails when stdin is not a TTY (e.g. piped). In that case,
    // skip terminal setup entirely rather than applying undefined stack bytes
    // via tcsetattr.
    var orig_termios: cross.c.termios = undefined;
    const stdin_is_tty = cross.c.tcgetattr(posix.STDIN_FILENO, &orig_termios) == 0;

    defer {
        if (stdin_is_tty) {
            _ = cross.c.tcsetattr(posix.STDIN_FILENO, cross.c.TCSAFLUSH, &orig_termios);
        }
        // Reset terminal modes on detach:
        const restore_seq = "\x1bc";
        _ = posix.write(posix.STDOUT_FILENO, restore_seq) catch {};
    }

    if (stdin_is_tty) {
        var raw_termios = orig_termios;
        //  set raw mode after successful connection.
        //      disables canonical mode (line buffering), input echoing, signal generation from
        //      control characters (like Ctrl+C), and flow control.
        cross.c.cfmakeraw(&raw_termios);

        // Additional granular raw mode settings for precise control
        // (matches what abduco and shpool do)
        raw_termios.c_cc[cross.c.VLNEXT] = cross.c._POSIX_VDISABLE; // Disable literal-next (Ctrl-V)
        // We want to intercept Ctrl+\ (SIGQUIT) so we can use it as a detach key
        raw_termios.c_cc[cross.c.VQUIT] = cross.c._POSIX_VDISABLE; // Disable SIGQUIT (Ctrl+\)
        raw_termios.c_cc[cross.c.VMIN] = 1; // Minimum chars to read: return after 1 byte
        raw_termios.c_cc[cross.c.VTIME] = 0; // Read timeout: no timeout, return immediately

        _ = cross.c.tcsetattr(posix.STDIN_FILENO, cross.c.TCSANOW, &raw_termios);
    }

    // Clear screen before attaching. This provides a clean slate before
    // the session restore.
    const clear_seq = "\x1b[2J\x1b[H";
    _ = try posix.write(posix.STDOUT_FILENO, clear_seq);

    const looper = try clientLoop(client_sock);
    switch (looper.kind) {
        .detach => return,
        .switch_session => {
            if (looper.session_name) |session_name| {
                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                const cwd = std.posix.getcwd(&cwd_buf) catch "";
                const target_path = socket.getSocketPath(
                    daemon.alloc,
                    daemon.cfg.socket_dir,
                    session_name,
                ) catch |err| switch (err) {
                    error.NameTooLong => return socket.printSessionNameTooLong(
                        session_name,
                        daemon.cfg.socket_dir,
                    ),
                    error.OutOfMemory => return err,
                };

                const clients = try std.ArrayList(*Client).initCapacity(daemon.alloc, 10);
                var target_daemon = Daemon{
                    .running = true,
                    .cfg = daemon.cfg,
                    .alloc = daemon.alloc,
                    .clients = clients,
                    .session_name = session_name,
                    .socket_path = target_path,
                    .pid = undefined,
                    .cwd = cwd,
                    .created_at = @intCast(std.time.timestamp()),
                    .leader_client_fd = null,
                };
                return attach(&target_daemon);
            }
        },
    }
}

fn writeFile(daemon: *Daemon, file_path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const sesh_result = try daemon.ensureSession();
    if (sesh_result.is_daemon) return;

    if (sesh_result.created) {
        try w.interface.print("session \"{s}\" created\n", .{daemon.session_name});
        try w.interface.flush();
    }
    const stdin_fd = posix.STDIN_FILENO;
    var stdin_buf = try std.ArrayList(u8).initCapacity(daemon.alloc, 4096);
    defer stdin_buf.deinit(daemon.alloc);

    while (true) {
        var tmp: [4096]u8 = undefined;
        const n = posix.read(stdin_fd, &tmp) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
        if (n == 0) break;
        try stdin_buf.appendSlice(daemon.alloc, tmp[0..n]);
    }

    const socket_path = socket.getSocketPath(
        daemon.alloc,
        daemon.cfg.socket_dir,
        daemon.session_name,
    ) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(
            daemon.session_name,
            daemon.cfg.socket_dir,
        ),
        error.OutOfMemory => return err,
    };
    var dir = try std.fs.openDirAbsolute(daemon.cfg.socket_dir, .{});
    defer dir.close();

    const result = ipc.probeSession(daemon.alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(dir, daemon.session_name);
            w.interface.print("cleaned up stale session {s}\n", .{daemon.session_name}) catch {};
        } else {
            w.interface.print(
                "session {s} is unresponsive ({s})\ndaemon may be busy: try again\n",
                .{ daemon.session_name, @errorName(err) },
            ) catch {};
        }
        w.interface.flush() catch {};
        return;
    };

    defer posix.close(result.fd);

    // Build wire payload: [u32 path len][path bytes][file content]
    var wire_buf = try std.ArrayList(u8).initCapacity(
        daemon.alloc,
        @sizeOf(u32) + file_path.len + stdin_buf.items.len,
    );
    defer wire_buf.deinit(daemon.alloc);
    const path_len: u32 = @intCast(file_path.len);
    try wire_buf.appendSlice(daemon.alloc, std.mem.asBytes(&path_len));
    try wire_buf.appendSlice(daemon.alloc, file_path);
    try wire_buf.appendSlice(daemon.alloc, stdin_buf.items);

    ipc.send(result.fd, .Write, wire_buf.items) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(daemon.alloc);
    defer sb.deinit();

    const n = sb.read(result.fd) catch return error.ReadFailed;
    if (n == 0) return error.ConnectionClosed;

    while (sb.next()) |msg| {
        if (msg.header.tag == .Ack) {
            try w.interface.print("file created {s}\n", .{file_path});
            try w.interface.flush();
            return;
        }
    }

    return error.NoAckReceived;
}

fn send(cfg: *Cfg, session_name: []const u8, socket_path: []const u8, text_parts: [][]const u8, tag: ipc.Tag) !void {
    const alloc = std.heap.c_allocator;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(alloc);

    if (text_parts.len > 0) {
        for (text_parts, 0..) |part, i| {
            if (i > 0) try payload.append(alloc, ' ');
            try payload.appendSlice(alloc, part);
        }
    } else {
        // Read from stdin when no text arguments provided.
        const stdin_fd = posix.STDIN_FILENO;
        if (!std.posix.isatty(stdin_fd)) {
            while (true) {
                var tmp: [4096]u8 = undefined;
                const n = posix.read(stdin_fd, &tmp) catch |err| {
                    if (err == error.WouldBlock) break;
                    return err;
                };
                if (n == 0) break;
                try payload.appendSlice(alloc, tmp[0..n]);
            }
            // Strip trailing newline from piped input; the caller is
            // responsible for including \r when submission is desired.
            // For .Output the caller controls exact bytes, so don't strip.
            if (tag != .Output and payload.items.len > 0 and payload.items[payload.items.len - 1] == '\n') {
                _ = payload.pop();
            }
        }
    }

    if (payload.items.len == 0) return error.TextRequired;

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const probe_result = ipc.probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(dir, session_name);
            try w.interface.print("cleaned up stale session {s}\n", .{session_name});
        } else {
            try w.interface.print(
                "session {s} is unresponsive ({s})\ndaemon may be busy: try again\n",
                .{ session_name, @errorName(err) },
            );
        }
        try w.interface.flush();
        return;
    };
    defer posix.close(probe_result.fd);

    ipc.send(probe_result.fd, tag, payload.items) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };
}

fn run(daemon: *Daemon, detached: bool, command_args: [][]const u8) !void {
    const alloc = daemon.alloc;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);

    var cmd_to_send: ?[]const u8 = null;
    var allocated_cmd: ?[]u8 = null;
    defer if (allocated_cmd) |cmd| alloc.free(cmd);

    const result = try daemon.ensureSession();
    if (result.is_daemon) return;

    if (result.created) {
        try w.interface.print("session \"{s}\" created\n", .{daemon.session_name});
        try w.interface.flush();
    }

    if (command_args.len > 0) {
        var cmd_list = std.ArrayList(u8).empty;
        defer cmd_list.deinit(alloc);

        for (command_args, 0..) |arg, i| {
            if (i > 0) try cmd_list.append(alloc, ' ');
            if (util.shellNeedsQuoting(arg)) {
                const quoted = try util.shellQuote(alloc, arg);
                defer alloc.free(quoted);
                try cmd_list.appendSlice(alloc, quoted);
            } else {
                try cmd_list.appendSlice(alloc, arg);
            }
        }

        // \r, not \n: once the shell is at the readline prompt the PTY is in
        // raw mode; readline's accept-line binds to CR. The first-ever run
        // works with \n only because it arrives during shell startup while
        // the line discipline is still canonical.
        try cmd_list.append(alloc, '\r');

        cmd_to_send = try cmd_list.toOwnedSlice(alloc);
        allocated_cmd = @constCast(cmd_to_send.?);
    } else {
        const stdin_fd = posix.STDIN_FILENO;
        if (!std.posix.isatty(stdin_fd)) {
            var stdin_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
            defer stdin_buf.deinit(alloc);

            while (true) {
                var tmp: [4096]u8 = undefined;
                const n = posix.read(stdin_fd, &tmp) catch |err| {
                    if (err == error.WouldBlock) break;
                    return err;
                };
                if (n == 0) break;
                try stdin_buf.appendSlice(alloc, tmp[0..n]);
            }

            if (stdin_buf.items.len > 0) {
                // Normalize any trailing newline to CR so readline (raw mode)
                // accepts each line.
                if (stdin_buf.items[stdin_buf.items.len - 1] == '\n') {
                    stdin_buf.items[stdin_buf.items.len - 1] = '\r';
                } else {
                    try stdin_buf.append(alloc, '\r');
                }

                cmd_to_send = try alloc.dupe(u8, stdin_buf.items);
                allocated_cmd = @constCast(cmd_to_send.?);
            }
        }
    }

    if (cmd_to_send == null) {
        return error.CommandRequired;
    }

    const client_sock = ipc.connectSession(daemon.socket_path) catch |err| {
        std.log.err("session not ready: {s}", .{@errorName(err)});
        return error.SessionNotReady;
    };
    defer posix.close(client_sock);

    var fds = try std.ArrayList(i32).initCapacity(alloc, 1);
    defer fds.deinit(alloc);
    try fds.append(alloc, client_sock);

    ipc.send(client_sock, .Run, cmd_to_send.?) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };

    const exit_code = try tail(fds, detached, true);
    posix.exit(exit_code);
}

const ClientResult = struct {
    kind: enum {
        detach,
        switch_session,
    },
    session_name: ?[]const u8,
};

fn setNonblocking(fd: i32) !usize {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK);
    return flags;
}

fn fillPollFds(
    alloc: std.mem.Allocator,
    poll_fds: *std.ArrayList(posix.pollfd),
    client_sock_fd: i32,
    sock_write_buf: []const u8,
    stdout_buf: []const u8,
) !void {
    poll_fds.clearRetainingCapacity();
    try poll_fds.append(alloc, .{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    var sock_events: i16 = posix.POLL.IN;
    if (sock_write_buf.len > 0) sock_events |= posix.POLL.OUT;
    try poll_fds.append(alloc, .{ .fd = client_sock_fd, .events = sock_events, .revents = 0 });
    try poll_fds.append(alloc, .{ .fd = sig_pipe[0], .events = posix.POLL.IN, .revents = 0 });

    if (stdout_buf.len > 0) {
        try poll_fds.append(alloc, .{
            .fd = posix.STDOUT_FILENO,
            .events = posix.POLL.OUT,
            .revents = 0,
        });
    }
}

fn handleSigEvent(alloc: std.mem.Allocator, sock_write_buf: *std.ArrayList(u8), revents: i16) !void {
    if (revents & posix.POLL.IN == 0) return;
    drainSignalPipe();
    const next_size = ipc.getTerminalSize(posix.STDOUT_FILENO);
    try ipc.appendMessage(alloc, sock_write_buf, .Resize, std.mem.asBytes(&next_size));
}

fn handleStdinEvent(
    alloc: std.mem.Allocator,
    sock_write_buf: *std.ArrayList(u8),
    revents: i16,
) !?ClientResult {
    const inp_flags = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;
    if (revents & inp_flags == 0) return null;

    var buf: [4096]u8 = undefined;
    const n_opt: ?usize = posix.read(posix.STDIN_FILENO, &buf) catch |err| {
        if (err == error.WouldBlock) return null;
        return err;
    };
    const n = n_opt orelse return null;
    if (n == 0) return ClientResult{ .kind = .detach, .session_name = null };

    const tag: ipc.Tag = if (util.isCtrlBackslash(buf[0..n])) .Detach else .Input;
    try ipc.appendMessage(
        alloc,
        sock_write_buf,
        tag,
        if (tag == .Detach) "" else buf[0..n],
    );
    return null;
}

fn handleDaemonEvent(
    alloc: std.mem.Allocator,
    client_sock_fd: i32,
    read_buf: *ipc.SocketBuffer,
    sock_write_buf: *std.ArrayList(u8),
    stdout_buf: *std.ArrayList(u8),
    revents: i16,
) !?ClientResult {
    if (revents & posix.POLL.IN == 0) return null;

    const n = read_buf.read(client_sock_fd) catch |err| {
        if (err == error.WouldBlock) return null;
        if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
            return ClientResult{ .kind = .detach, .session_name = null };
        }
        std.log.err("daemon read err={s}", .{@errorName(err)});
        return err;
    };
    if (n == 0) return ClientResult{ .kind = .detach, .session_name = null };

    while (read_buf.next()) |msg| {
        switch (msg.header.tag) {
            .Output => {
                if (msg.payload.len > 0) try stdout_buf.appendSlice(alloc, msg.payload);
            },
            .Resize => {
                const next_size = ipc.getTerminalSize(posix.STDOUT_FILENO);
                try ipc.appendMessage(
                    alloc,
                    sock_write_buf,
                    .Resize,
                    std.mem.asBytes(&next_size),
                );
            },
            .Switch => {
                return ClientResult{
                    .kind = .switch_session,
                    .session_name = try alloc.dupe(u8, msg.payload),
                };
            },
            else => {},
        }
    }
    return null;
}

fn flushSocketBuf(
    alloc: std.mem.Allocator,
    client_sock_fd: i32,
    sock_write_buf: *std.ArrayList(u8),
    revents: i16,
) !?ClientResult {
    if (revents & posix.POLL.OUT == 0 or sock_write_buf.items.len == 0) return null;

    const n = posix.write(client_sock_fd, sock_write_buf.items) catch |err| {
        if (err == error.WouldBlock) return null;
        if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
            return ClientResult{ .kind = .detach, .session_name = null };
        }
        return err;
    };
    if (n > 0) try sock_write_buf.replaceRange(alloc, 0, n, &[_]u8{});
    return null;
}

fn flushTerminal(alloc: std.mem.Allocator, stdout_buf: *std.ArrayList(u8)) !void {
    if (stdout_buf.items.len == 0) return;

    const n = posix.write(posix.STDOUT_FILENO, stdout_buf.items) catch |err| {
        if (err == error.WouldBlock) return;
        return err;
    };
    if (n > 0) try stdout_buf.replaceRange(alloc, 0, n, &[_]u8{});
}

fn clientLoop(client_sock_fd: i32) !ClientResult {
    const alloc = std.heap.c_allocator;
    defer posix.close(client_sock_fd);

    try openSignalPipe();
    installWakeHandler(posix.SIG.WINCH);

    _ = try setNonblocking(client_sock_fd);
    const stdin_orig_flags = try setNonblocking(posix.STDIN_FILENO);
    defer _ = posix.fcntl(posix.STDIN_FILENO, posix.F.SETFL, stdin_orig_flags) catch {};

    var sock_write_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer sock_write_buf.deinit(alloc);

    var stdout_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer stdout_buf.deinit(alloc);

    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(alloc, 4);
    defer poll_fds.deinit(alloc);

    var read_buf = try ipc.SocketBuffer.init(alloc);
    defer read_buf.deinit();

    const size = ipc.getTerminalSize(posix.STDOUT_FILENO);
    try ipc.appendMessage(alloc, &sock_write_buf, .Init, std.mem.asBytes(&size));

    std.debug.assert(client_sock_fd >= 0);
    std.debug.assert(sig_pipe[0] >= 0);

    while (true) {
        try fillPollFds(alloc, &poll_fds, client_sock_fd, sock_write_buf.items, stdout_buf.items);
        _ = try posix.poll(poll_fds.items, -1);

        try handleSigEvent(alloc, &sock_write_buf, poll_fds.items[2].revents);

        if (try handleStdinEvent(
            alloc,
            &sock_write_buf,
            poll_fds.items[0].revents,
        )) |r| return r;

        if (try handleDaemonEvent(
            alloc,
            client_sock_fd,
            &read_buf,
            &sock_write_buf,
            &stdout_buf,
            poll_fds.items[1].revents,
        )) |r| return r;

        if (try flushSocketBuf(
            alloc,
            client_sock_fd,
            &sock_write_buf,
            poll_fds.items[1].revents,
        )) |r| return r;

        try flushTerminal(alloc, &stdout_buf);

        const err_events = posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;
        if (poll_fds.items[1].revents & err_events != 0) {
            return ClientResult{ .kind = .detach, .session_name = null };
        }
    }
}

const ClientMsgAction = enum {
    next,
    done,
    kill,
};

fn fillDaemonPollFds(
    alloc: std.mem.Allocator,
    poll_fds: *std.ArrayList(posix.pollfd),
    server_sock_fd: i32,
    pty_fd: i32,
    pty_write_buf: []const u8,
    clients: []const *Client,
) !void {
    poll_fds.clearRetainingCapacity();
    try poll_fds.append(alloc, .{ .fd = server_sock_fd, .events = posix.POLL.IN, .revents = 0 });

    var pty_events: i16 = posix.POLL.IN;
    if (pty_write_buf.len > 0) pty_events |= posix.POLL.OUT;
    try poll_fds.append(alloc, .{ .fd = pty_fd, .events = pty_events, .revents = 0 });
    try poll_fds.append(alloc, .{ .fd = sig_pipe[0], .events = posix.POLL.IN, .revents = 0 });

    for (clients) |client| {
        var events: i16 = posix.POLL.IN;
        if (client.has_pending_output) events |= posix.POLL.OUT;
        try poll_fds.append(alloc, .{ .fd = client.socket_fd, .events = events, .revents = 0 });
    }
}

fn handlePtyRead(
    daemon: *Daemon,
    pty_fd: i32,
    vt_stream: *ghostty_vt.TerminalStream,
    revents: i16,
) bool {
    const inp_flags = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;
    if (revents & inp_flags == 0) return false;

    var buf: [4096]u8 = undefined;
    const n_opt: ?usize = posix.read(pty_fd, &buf) catch |err| {
        if (err == error.WouldBlock) return false;
        return true;
    };
    const n = n_opt orelse return false;
    if (n == 0) return true;

    vt_stream.nextSlice(buf[0..n]);
    daemon.has_pty_output = true;

    if (!daemon.has_terminal_client and daemon.pty_write_buf.items.len < Daemon.PTY_WRITE_BUF_MAX) {
        util.respondToDeviceAttributes(daemon.alloc, &daemon.pty_write_buf, buf[0..n]);
    }

    if (daemon.is_task_mode and daemon.task_exit_code == null) {
        if (util.findTaskExitMarker(buf[0..n])) |exit_code| {
            daemon.task_exit_code = exit_code;
            daemon.task_ended_at = @intCast(std.time.timestamp());
            for (daemon.clients.items) |c| {
                ipc.appendMessage(daemon.alloc, &c.write_buf, .TaskComplete, &[_]u8{exit_code}) catch {};
                c.has_pending_output = true;
            }
        }
    }

    const broadcast_data = util.rewritePromptRedraw(daemon.alloc, buf[0..n]) orelse buf[0..n];
    defer if (broadcast_data.ptr != buf[0..n].ptr) daemon.alloc.free(broadcast_data);
    for (daemon.clients.items) |client| {
        ipc.appendMessage(daemon.alloc, &client.write_buf, .Output, broadcast_data) catch |err| {
            std.log.warn("failed to buffer output for client err={s}", .{@errorName(err)});
            continue;
        };
        client.has_pending_output = true;
    }
    return false;
}

fn processClientMessages(
    daemon: *Daemon,
    client: *Client,
    i: usize,
    pty_fd: i32,
    vt_stream: *ghostty_vt.TerminalStream,
    term: *ghostty_vt.Terminal,
) !ClientMsgAction {
    while (client.read_buf.next()) |msg| {
        switch (msg.header.tag) {
            .Input => try daemon.handleInput(client, msg.payload),
            .Output => try daemon.handleOutput(msg.payload, vt_stream),
            .Init => try daemon.handleInit(client, pty_fd, term, msg.payload),
            .Switch => try daemon.handleSwitch(msg.payload),
            .Resize => try daemon.handleResize(client, pty_fd, term, msg.payload),
            .Detach => {
                daemon.handleDetach(client, i);
                return .done;
            },
            .DetachAll => {
                daemon.handleDetachAll();
                return .done;
            },
            .Kill => return .kill,
            .Info => try daemon.handleInfo(client),
            .History => try daemon.handleHistory(client, term, msg.payload),
            .Run => try daemon.handleRun(client, msg.payload),
            .Ack, .TaskComplete => {},
            .Write => try daemon.handleWrite(client, msg.payload),
            _ => std.log.warn("ignoring unknown IPC tag={d}", .{@intFromEnum(msg.header.tag)}),
        }
    }
    return .next;
}

fn acceptClient(daemon: *Daemon, server_sock_fd: i32, revents: i16) !bool {
    if (revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
        std.log.err("server socket error revents={d}", .{revents});
        return true;
    }
    if (revents & posix.POLL.IN == 0) return false;

    const client_fd = try posix.accept(server_sock_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
    const client = try daemon.alloc.create(Client);
    client.* = Client{
        .alloc = daemon.alloc,
        .socket_fd = client_fd,
        .read_buf = try ipc.SocketBuffer.init(daemon.alloc),
        .write_buf = undefined,
    };
    client.write_buf = try std.ArrayList(u8).initCapacity(client.alloc, 65536);
    try daemon.clients.append(daemon.alloc, client);
    std.log.info("client connected fd={d} total={d}", .{ client_fd, daemon.clients.items.len });
    return false;
}

fn flushPtyWrite(daemon: *Daemon, pty_fd: i32, revents: i16) void {
    if (revents & posix.POLL.OUT == 0) return;
    while (daemon.pty_write_buf.items.len > 0) {
        const n = posix.write(pty_fd, daemon.pty_write_buf.items) catch |err| {
            if (err != error.WouldBlock) {
                std.log.warn("pty write failed: {s}", .{@errorName(err)});
                daemon.pty_write_buf.clearRetainingCapacity();
            }
            return;
        };
        if (n == 0) return;
        daemon.pty_write_buf.replaceRange(daemon.alloc, 0, n, &[_]u8{}) catch unreachable;
    }
}

fn processClientEvents(
    daemon: *Daemon,
    poll_fds: *const std.ArrayList(posix.pollfd),
    term: *ghostty_vt.Terminal,
    vt_stream: *ghostty_vt.TerminalStream,
    pty_fd: i32,
) !bool {
    var i: usize = daemon.clients.items.len;
    const num_polled_clients = poll_fds.items.len - 3;
    if (i > num_polled_clients) i = num_polled_clients;

    while (i > 0) {
        i -= 1;
        const client = daemon.clients.items[i];
        const revents = poll_fds.items[i + 3].revents;

        if (revents & posix.POLL.IN != 0) {
            const n = client.read_buf.read(client.socket_fd) catch |err| {
                if (err == error.WouldBlock) continue;
                std.log.debug("client read err={s} fd={d}", .{ @errorName(err), client.socket_fd });
                const last = daemon.closeClient(client, i, false);
                if (last) return true;
                continue;
            };
            if (n == 0) {
                const last = daemon.closeClient(client, i, false);
                if (last) return true;
                continue;
            }

            switch (try processClientMessages(daemon, client, i, pty_fd, vt_stream, term)) {
                .kill => return true,
                .done => break,
                .next => {},
            }
        }

        if (revents & posix.POLL.OUT != 0) {
            const n = posix.write(client.socket_fd, client.write_buf.items) catch |err| {
                if (err == error.WouldBlock) continue;
                const last = daemon.closeClient(client, i, false);
                if (last) return true;
                continue;
            };
            if (n > 0) {
                client.write_buf.replaceRange(daemon.alloc, 0, n, &[_]u8{}) catch unreachable;
            }
            if (client.write_buf.items.len == 0) {
                client.has_pending_output = false;
            }
        }

        if (revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
            const last = daemon.closeClient(client, i, false);
            if (last) return true;
        }
    }
    return false;
}

fn daemonLoop(daemon: *Daemon, server_sock_fd: i32, pty_fd: i32) !void {
    std.log.info("daemon started session={s} pty_fd={d}", .{ daemon.session_name, pty_fd });
    daemon.pty_fd = pty_fd;
    try openSignalPipe();
    installWakeHandler(posix.SIG.TERM);

    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(daemon.alloc, 8);
    defer poll_fds.deinit(daemon.alloc);

    const init_size = ipc.getTerminalSize(pty_fd);
    var term = try ghostty_vt.Terminal.init(daemon.alloc, .{
        .cols = init_size.cols,
        .rows = init_size.rows,
        .max_scrollback = daemon.cfg.max_scrollback,
    });
    defer term.deinit(daemon.alloc);
    var vt_stream = term.vtStream();
    defer vt_stream.deinit();

    std.debug.assert(server_sock_fd >= 0);
    std.debug.assert(pty_fd >= 0);

    while (daemon.running) {
        try fillDaemonPollFds(daemon.alloc, &poll_fds, server_sock_fd, pty_fd, daemon.pty_write_buf.items, daemon.clients.items);
        _ = try posix.poll(poll_fds.items, -1);

        if (poll_fds.items[2].revents & posix.POLL.IN != 0) {
            drainSignalPipe();
            std.log.info("SIGTERM received, shutting down gracefully session={s}", .{daemon.session_name});
            break;
        }

        if (try acceptClient(daemon, server_sock_fd, poll_fds.items[0].revents)) break;
        if (handlePtyRead(daemon, pty_fd, &vt_stream, poll_fds.items[1].revents)) break;
        flushPtyWrite(daemon, pty_fd, poll_fds.items[1].revents);
        if (try processClientEvents(daemon, &poll_fds, &term, &vt_stream, pty_fd)) break;
    }
}

fn wakeSignalPipe(_: i32, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = std.c._errno().*;
    _ = std.c.write(sig_pipe[1], "x", 1);
    std.c._errno().* = saved;
}

// std.posix.poll retries EINTR internally, so SA_RESTART is moot -- neither
// setting wakes the loop. The handler writes to sig_pipe instead; poll()
// wakes on its read end.
fn installWakeHandler(sig: u6) void {
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = wakeSignalPipe },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO,
    };
    posix.sigaction(sig, &act, null);
}

fn ignoreSigpipe() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);
}
