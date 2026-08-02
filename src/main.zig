const std = @import("std");
const build_options = @import("build_options");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const completions = @import("completions.zig");
const util = @import("util.zig");
const cross = @import("cross.zig");
const socket = @import("socket.zig");
const label = @import("label.zig");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const Cfg = @import("cfg.zig");
const loop = @import("loop.zig");
const Client = loop.Client;
const Daemon = loop.Daemon;
const version = build_options.version;
const ghostty_version = build_options.ghostty_version;

pub const std_options: std.Options = .{
    .logFn = log.zmxLogFn,
    .log_level = .debug,
};

/// This is the entry point for the CLI.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Every subcommand may write to a Unix-domain socket; a peer that
    // disappears between probe and send would otherwise kill us before
    // write() can return BrokenPipe. Inherited across fork, so this also
    // covers the daemon.
    signal.ignoreSigpipe();

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next(); // skip program name

    var cfg = try Cfg.init(gpa, io);
    defer cfg.deinit(gpa);

    const log_path = try std.fs.path.join(gpa, &.{ cfg.log_dir, "zmx.log" });
    defer gpa.free(log_path);
    const log_mode = std.Io.File.Permissions.fromMode(@intCast(cfg.log_mode));
    try log.log_system.init(io, log_path, log_mode);
    defer log.log_system.deinit();

    const shell_env = init.environ_map.get("SHELL") orelse "/bin/sh";

    const cmd = args.next() orelse {
        return list(gpa, io, &cfg, false);
    };

    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "--version")) {
        return printVersion(io, &cfg);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "-h")) {
        return help(io);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "l") or std.mem.eql(u8, cmd, "ls")) {
        var short = false;
        while (args.next()) |arg| {
            if (detectHelp(arg)) return help(io);
            if (std.mem.eql(u8, arg, "--short")) short = true;
        }
        return list(gpa, io, &cfg, short);
    } else if (std.mem.eql(u8, cmd, "get") or std.mem.eql(u8, cmd, "g")) {
        const sesh_name = args.next() orelse return error.SessionNameRequired;
        if (detectHelp(sesh_name)) return help(io);
        const sesh = try socket.resolveSessionOrEnv(gpa, io, sesh_name);
        defer gpa.free(sesh);
        const single_kv = args.next() orelse "";
        return labelGet(gpa, io, &cfg, sesh, single_kv);
    } else if (std.mem.eql(u8, cmd, "set")) {
        const sesh_name = args.next() orelse return error.SessionNameRequired;
        if (detectHelp(sesh_name)) return help(io);
        const sesh = try socket.resolveSessionOrEnv(gpa, io, sesh_name);
        defer gpa.free(sesh);

        var kvs = std.ArrayList(u8).empty;
        defer kvs.deinit(gpa);
        var first = true;
        while (args.next()) |arg| {
            if (!first) try kvs.append(gpa, ' ');
            try kvs.appendSlice(gpa, arg);
            first = false;
        }
        return labelSet(gpa, io, &cfg, sesh, kvs.items);
    } else if (std.mem.eql(u8, cmd, "clear")) {
        const sesh_name = args.next() orelse return error.SessionNameRequired;
        if (detectHelp(sesh_name)) return help(io);
        const sesh = try socket.resolveSessionOrEnv(gpa, io, sesh_name);
        defer gpa.free(sesh);
        return labelClear(gpa, io, &cfg, sesh);
    } else if (std.mem.eql(u8, cmd, "completions") or std.mem.eql(u8, cmd, "c")) {
        const arg = args.next() orelse return;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return help(io);
        }
        const shell = completions.Shell.fromString(arg) orelse return;
        return printCompletions(io, shell);
    } else if (std.mem.eql(u8, cmd, "detach") or std.mem.eql(u8, cmd, "d")) {
        return detachAll(gpa, io, &cfg);
    } else if (std.mem.eql(u8, cmd, "history") or std.mem.eql(u8, cmd, "hi")) {
        var session_name: ?[]const u8 = null;
        var format: util.HistoryFormat = .plain;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return help(io);
            } else if (std.mem.eql(u8, arg, "--vt")) {
                format = .vt;
            } else if (std.mem.eql(u8, arg, "--html")) {
                format = .html;
            } else if (session_name == null) {
                session_name = arg;
            }
        }
        const sesh_env = socket.getSeshNameFromEnv();
        const sesh = try socket.getSeshName(gpa, session_name orelse sesh_env);
        defer gpa.free(sesh);
        return history(gpa, io, &cfg, sesh, format);
    } else if (std.mem.eql(u8, cmd, "attach") or std.mem.eql(u8, cmd, "a")) {
        const session_name = args.next() orelse "";
        if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
            return help(io);
        }

        var command_args: std.ArrayList([]const u8) = .empty;
        defer command_args.deinit(gpa);
        while (args.next()) |arg| {
            try command_args.append(gpa, arg);
        }

        var command: ?[][]const u8 = null;
        if (command_args.items.len > 0) {
            command = command_args.items;
        }

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const cwd = cwd_buf[0..cwd_len];

        const sesh = try socket.getSeshName(gpa, session_name);
        defer gpa.free(sesh);
        const socket_path = socket.getSocketPath(gpa, cfg.socket_dir, sesh) catch |err| switch (err) {
            error.NameTooLong => return socket.printSessionNameTooLong(io, sesh, cfg.socket_dir),
            error.OutOfMemory => return err,
        };
        var daemon = Daemon.init(io, &cfg, sesh, socket_path);
        daemon.command = command;
        daemon.cwd = cwd;
        daemon.shell = shell_env;
        std.log.info("socket path={s}", .{daemon.socket_path});
        return attach(gpa, io, &daemon);
    } else if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "r")) {
        const session_name = args.next() orelse "";
        if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
            return help(io);
        }

        var cmd_args_raw: std.ArrayList([]const u8) = .empty;
        defer cmd_args_raw.deinit(gpa);
        var detached = false;
        while (args.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "-d")) {
                detached = true;
            } else {
                try cmd_args_raw.append(gpa, arg);
            }
        }

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const cwd = cwd_buf[0..cwd_len];

        const sesh = try socket.getSeshName(gpa, session_name);
        defer gpa.free(sesh);
        const socket_path = socket.getSocketPath(gpa, cfg.socket_dir, sesh) catch |err| switch (err) {
            error.NameTooLong => return socket.printSessionNameTooLong(io, sesh, cfg.socket_dir),
            error.OutOfMemory => return err,
        };
        defer gpa.free(socket_path);
        var daemon = Daemon.init(io, &cfg, sesh, socket_path);
        daemon.cwd = cwd;
        daemon.is_task_mode = true;
        daemon.shell = shell_env;
        std.log.info("socket path={s}", .{daemon.socket_path});
        return run(gpa, io, &daemon, detached, cmd_args_raw.items);
    } else if (std.mem.eql(u8, cmd, "send") or std.mem.eql(u8, cmd, "s")) {
        const session_name = args.next() orelse "";
        if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
            return help(io);
        }
        if (session_name.len == 0) return error.SessionNameRequired;

        var text_parts: std.ArrayList([]const u8) = .empty;
        defer text_parts.deinit(gpa);
        while (args.next()) |arg| {
            try text_parts.append(gpa, arg);
        }

        const sesh = try socket.getSeshName(gpa, session_name);
        defer gpa.free(sesh);
        const socket_path = socket.getSocketPath(gpa, cfg.socket_dir, sesh) catch |err| switch (err) {
            error.NameTooLong => return socket.printSessionNameTooLong(io, sesh, cfg.socket_dir),
            error.OutOfMemory => return err,
        };
        return send(gpa, io, &cfg, sesh, socket_path, text_parts.items, .Send);
    } else if (std.mem.eql(u8, cmd, "print") or std.mem.eql(u8, cmd, "p")) {
        const session_name = args.next() orelse "";
        if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
            return help(io);
        }
        if (session_name.len == 0) return error.SessionNameRequired;

        var text_parts: std.ArrayList([]const u8) = .empty;
        defer text_parts.deinit(gpa);
        while (args.next()) |arg| {
            try text_parts.append(gpa, arg);
        }

        const sesh = try socket.getSeshName(gpa, session_name);
        defer gpa.free(sesh);
        const socket_path = socket.getSocketPath(gpa, cfg.socket_dir, sesh) catch |err| switch (err) {
            error.NameTooLong => return socket.printSessionNameTooLong(io, sesh, cfg.socket_dir),
            error.OutOfMemory => return err,
        };
        return send(gpa, io, &cfg, sesh, socket_path, text_parts.items, .Output);
    } else if (std.mem.eql(u8, cmd, "kill") or std.mem.eql(u8, cmd, "k")) {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
        const stderr = &stderr_writer.interface;

        var matchers: std.ArrayList(socket.SessionMatch) = .empty;
        defer {
            for (matchers.items) |m| {
                gpa.free(m.name);
            }
            matchers.deinit(gpa);
        }
        var force = false;
        while (args.next()) |session_name| {
            if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
                return help(io);
            }
            if (std.mem.eql(u8, session_name, "--force")) {
                force = true;
                continue;
            }
            const m = try socket.parseSessionArg(gpa, session_name);
            try matchers.append(gpa, m);
        }
        if (matchers.items.len == 0) {
            return error.SessionNameRequired;
        }
        var sessions = try util.get_session_entries(gpa, io, cfg.socket_dir);
        defer {
            for (sessions.items) |session| {
                session.deinit(gpa);
            }
            sessions.deinit(gpa);
        }

        for (sessions.items) |session| {
            for (matchers.items) |m| {
                if (!m.matches(session.name)) {
                    continue;
                }

                kill(gpa, io, &cfg, session.name, force) catch |err| {
                    try stderr.print(
                        "failed to kill session={s}: {s}\n",
                        .{ session.name, @errorName(err) },
                    );
                    try stderr.flush();
                };
                break;
            }
        }
    } else if (std.mem.eql(u8, cmd, "wait") or std.mem.eql(u8, cmd, "w")) {
        var matchers: std.ArrayList(socket.SessionMatch) = .empty;
        defer {
            for (matchers.items) |m| {
                gpa.free(m.name);
            }
            matchers.deinit(gpa);
        }
        while (args.next()) |session_name| {
            if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
                return help(io);
            }
            const m = try socket.parseSessionArg(gpa, session_name);
            try matchers.append(gpa, m);
        }
        if (matchers.items.len == 0) {
            return error.SessionNameRequired;
        }
        return wait(gpa, io, &cfg, matchers);
    } else if (std.mem.eql(u8, cmd, "tail") or std.mem.eql(u8, cmd, "t")) {
        var matchers: std.ArrayList(socket.SessionMatch) = .empty;
        defer {
            for (matchers.items) |m| {
                gpa.free(m.name);
            }
            matchers.deinit(gpa);
        }
        while (args.next()) |session_name| {
            if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
                return help(io);
            }
            const m = try socket.parseSessionArg(gpa, session_name);
            try matchers.append(gpa, m);
        }
        if (matchers.items.len == 0) {
            return error.SessionNameRequired;
        }

        // Resolve matchers against session list to get actual session names.
        var resolved_names: std.ArrayList([]const u8) = .empty;
        defer {
            for (resolved_names.items) |name| {
                gpa.free(name);
            }
            resolved_names.deinit(gpa);
        }

        var any_prefix = false;
        for (matchers.items) |m| {
            if (m.is_prefix) {
                any_prefix = true;
                break;
            }
        }

        if (any_prefix) {
            var sessions = try util.get_session_entries(gpa, io, cfg.socket_dir);
            defer {
                for (sessions.items) |session| {
                    session.deinit(gpa);
                }
                sessions.deinit(gpa);
            }
            for (sessions.items) |session| {
                for (matchers.items) |m| {
                    if (m.matches(session.name)) {
                        try resolved_names.append(gpa, try gpa.dupe(u8, session.name));
                        break;
                    }
                }
            }
        }
        // Add exact-match names directly.
        for (matchers.items) |m| {
            if (!m.is_prefix) {
                try resolved_names.append(gpa, try gpa.dupe(u8, m.name));
            }
        }

        var client_socket_fds = try std.ArrayList(i32).initCapacity(gpa, resolved_names.items.len);
        defer {
            for (client_socket_fds.items) |client_fd| {
                lib_posix.close(client_fd);
            }
            client_socket_fds.deinit(gpa);
        }

        for (resolved_names.items) |session_name| {
            const socket_path = socket.getSocketPath(gpa, cfg.socket_dir, session_name) catch |err| switch (err) {
                error.NameTooLong => return socket.printSessionNameTooLong(init.io, session_name, cfg.socket_dir),
                error.OutOfMemory => return err,
            };
            const client_sock = try socket.sessionConnect(socket_path);
            try client_socket_fds.append(gpa, client_sock);
        }
        _ = try tail(gpa, client_socket_fds, false, false);
    } else if (std.mem.eql(u8, cmd, "write") or std.mem.eql(u8, cmd, "wr")) {
        const session_name = args.next() orelse "";
        if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
            return help(io);
        }
        if (session_name.len == 0) return error.SessionNameRequired;
        const file_path = args.next() orelse "";
        if (std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h")) {
            return help(io);
        }
        if (file_path.len == 0) return error.FilePathRequired;

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const cwd = cwd_buf[0..cwd_len];
        const sesh = try socket.getSeshName(gpa, session_name);
        defer gpa.free(sesh);
        const socket_path = socket.getSocketPath(gpa, cfg.socket_dir, sesh) catch |err| switch (err) {
            error.NameTooLong => return socket.printSessionNameTooLong(io, sesh, cfg.socket_dir),
            error.OutOfMemory => return err,
        };
        var daemon = Daemon.init(io, &cfg, sesh, socket_path);
        daemon.is_task_mode = true;
        daemon.cwd = cwd;
        daemon.shell = shell_env;
        std.log.info("socket path={s}", .{daemon.socket_path});
        try writeFile(gpa, io, &daemon, file_path);
    } else {
        return help(io);
    }
}

fn help(io: std.Io) !void {
    const help_text =
        \\zmx - session persistence for terminal processes
        \\
        \\Usage: zmx <command> [args...]
        \\
        \\Commands:
        \\  [a]ttach <name> [command...]             Attach to session, creating if needed
        \\  [r]un <name> [-d] [command...]           Send command without attaching
        \\  [s]end <name> <text...>                  Send raw input to session PTY
        \\  [p]rint <name> <text...>                 Inject text into session display
        \\  [wr]ite <name> <file_path>               Write stdin to file_path through the session
        \\  [d]etach                                 Detach all clients (ctrl+\\ for current client)
        \\  [l]ist|ls [--short|--where k=v]          List active sessions
        \\  [g]et <name>                             Get session labels
        \\  set <name> k=v ...                     Set session labels (k= to remove)
        \\  [cl]ear <name>                           Clear all session labels
        \\  [k]ill <name>... [--force]               Kill session and all attached clients
        \\  [hi]story <name> [--vt|--html]           Output session scrollback
        \\  [w]ait <name>...                         Wait for session tasks to complete
        \\  [t]ail <name>...                         Follow session output
        \\  [c]ompletions <shell>                    Shell completions (bash, zsh, fish, nu)
        \\  [v]ersion                                Show version and metadata (socket dir, log dir)
        \\  [h]elp                                   Show this help
        \\
        \\Attach:
        \\  This will spawn a login $SHELL with a PTY.  You can provide a
        \\  command instead of creating a shell.
        \\
        \\  Examples:
        \\    zmx attach dev
        \\    zmx attach dev vim
        \\
        \\History:
        \\  This should generally be used with `tail` to print the last lines
        \\  of the session's scrollback history.
        \\
        \\  Examples:
        \\    zmx history <session> | tail -100
        \\
        \\Run:
        \\  Commands run inside a PTY using bash
        \\  Commands are passed as-is: do not wrap in quotes.
        \\  Commands run sequentially: do not send multiple in parallel.
        \\  Stdin is redirected from /dev/null to prevent interactive programs
        \\  (pagers, editors, prompts) from blocking. Use `zmx send` for
        \\  commands that need user input, or pipe data directly:
        \\    echo "data" | zmx run dev cat
        \\
        \\  `-d` will detach from the calling terminal. Use `wait` to track
        \\  its status.
        \\
        \\  Examples:
        \\    zmx run dev ls
        \\    zmx run dev zig build
        \\    zmx run dev grep -r TODO src
        \\    zmx run dev git log --oneline          # pager won't block
        \\    echo "hello" | zmx run dev cat         # piped stdin still works
        \\
        \\    # heredoc
        \\    printf "cat << 'EOF'\r\nHello $USER\r\nToday is $(date).\r\nEOF" | zmx run dev
        \\
        \\    # non-blocking
        \\    zmx run dev -d sleep 10
        \\    zmx wait dev
        \\
        \\Send:
        \\  Sends raw text to the session's PTY input (fire-and-forget).
        \\  Unlike `run`, no completion marker is appended and no exit code
        \\  is tracked.  Useful for TUI applications, interactive prompts,
        \\  or any program that reads stdin directly.
        \\
        \\  Text is sent byte-for-byte with no automatic carriage return.
        \\  Append \r yourself when you want the shell to execute a command.
        \\
        \\  Text can also be piped via stdin:
        \\    printf 'ls -la\r' | zmx send dev
        \\
        \\  Examples:
        \\    printf 'echo hello\r' | zmx send dev
        \\    zmx send dev $(printf '\x03')
        \\    zmx send dev /compact
        \\
        \\Print:
        \\  Injects text directly into the session display and scrollback.
        \\  Never touches the PTY input -- the shell sees nothing.
        \\  Caller is responsible for newlines (\\r\\n).
        \\
        \\  Examples:
        \\    printf '\\r\\nhello\\r\\n' | zmx print dev
        \\    zmx print dev "$(printf '\\r\\nalert\\r\\n')"
        \\
        \\Write:
        \\  Writes stdin to file_path inside the session. Works over SSH.
        \\  file_path can be absolute or relative to the session shell's cwd.
        \\  Requires base64 and printf in the remote environment.
        \\  Large files are chunked automatically (~48KB per chunk).
        \\  File path must not contain single quotes.
        \\
        \\  Examples:
        \\    echo "hello" | zmx write dev /tmp/hello.txt
        \\    cat main.zig | zmx write dev src/main.zig
        \\
        \\Wait:
        \\  Used with a detached run task to track its status.  Multiple
        \\  sessions can be provided.
        \\
        \\  Examples:
        \\    zmx run -d dev sleep 10
        \\    zmx wait dev
        \\    zmx wait dev other
        \\
        \\Labels:
        \\  Attach key=value labels to live sessions for discovery and
        \\  filtering. Labels are in-memory and scoped to session lifetime.
        \\
        \\  Examples:
        \\    zmx set dev project=zmx env=dev
        \\    zmx set dev project=            # unset a label
        \\    zmx set . status=fail           # "." resolves to current session
        \\    zmx get dev
        \\    zmx get dev project
        \\    zmx set next "$(zmx get prev)"  # set labels from other session
        \\    zmx list | grep project=zmx
        \\    zmx clear dev
        \\
        \\Environment variables:
        \\  SHELL                Default shell for new sessions
        \\  ZMX_DIR              Socket directory (priority 1)
        \\  XDG_RUNTIME_DIR      Socket directory (priority 2)
        \\  TMPDIR               Socket directory (priority 3)
        \\  ZMX_SESSION          Session name (injected automatically)
        \\  ZMX_SESSION_PREFIX   Prefix added to all session names
        \\  ZMX_DIR_MODE         Sets mode for socket and log directories (octal, defaults to 0750)
        \\  ZMX_LOG_MODE         Sets mode for log files (octal, defaults to 0640)
        \\  ZMX_LOG_INPUT        Hex-dump PTY input to the session log (records
        \\                       keystrokes, including passwords; off by default)
        \\
    ;
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(help_text, .{});
    try w.interface.flush();
}

fn printVersion(io: std.Io, cfg: *Cfg) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(
        "zmx\t\t{s}\nghostty_vt\t{s}\nsocket_dir\t{s}\nlog_dir\t\t{s}\n",
        .{ version, ghostty_version, cfg.socket_dir, cfg.log_dir },
    );
    try w.interface.flush();
}

fn printCompletions(io: std.Io, shell: completions.Shell) !void {
    const script = shell.getCompletionScript();
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("{s}\n", .{script});
    try w.interface.flush();
}

fn detectHelp(arg: []const u8) bool {
    return (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"));
}

fn tail(alloc: std.mem.Allocator, client_socket_fds: std.ArrayList(i32), detached: bool, is_run_cmd: bool) !u8 {
    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(alloc, 4);
    defer poll_fds.deinit(alloc);

    var read_buf = try ipc.SocketBuffer.init(alloc);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer stdout_buf.deinit(alloc);

    var is_first_line = true;
    var task_complete_code: ?u8 = null;

    while (true) {
        poll_fds.clearRetainingCapacity();

        // Poll socket for read
        for (client_socket_fds.items) |client_sock_fd| {
            try poll_fds.append(alloc, .{
                .fd = client_sock_fd,
                .events = lib_posix.POLL.IN,
                .revents = 0,
            });
        }

        // Poll for write if we have pending data
        if (stdout_buf.items.len > 0) {
            try poll_fds.append(alloc, .{
                .fd = lib_posix.STDOUT_FILENO,
                .events = lib_posix.POLL.OUT,
                .revents = 0,
            });
        }

        _ = lib_posix.poll(poll_fds.items, -1) catch |err| {
            if (err == error.Interrupted) continue; // EINTR from signal, loop again
            return err;
        };

        // Handle socket read (incoming Output messages from daemon)
        for (poll_fds.items) |*poll_fd| {
            if (poll_fd.revents & lib_posix.POLL.IN != 0) {
                const n = read_buf.read(poll_fd.fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                        return 1;
                    }
                    std.log.err("daemon read err={s}", .{@errorName(err)});
                    return err;
                };
                if (n == 0) {
                    // Server closed connection. If we got task completion,
                    // return the exit code. Otherwise fall back to 0.
                    if (task_complete_code) |exit_code| {
                        return exit_code;
                    }
                    return 0;
                }

                while (read_buf.next()) |msg| {
                    switch (msg.header.tag) {
                        .Ack => {
                            if (detached) {
                                _ = lib_posix.write(lib_posix.STDOUT_FILENO, "command sent!\n") catch |err| blk: {
                                    if (err == error.WouldBlock) break :blk 0;
                                    return err;
                                };
                                return 0;
                            }
                        },
                        .Output => {
                            if (msg.payload.len > 0) {
                                // Fallback: scan output for task exit marker in case
                                // .TaskComplete was lost (e.g. daemon exited before
                                // flushing). This ensures we detect completion even
                                // when the IPC message doesn't arrive.
                                if (task_complete_code == null and is_run_cmd) {
                                    if (util.findTaskExitMarker(msg.payload)) |ec| {
                                        task_complete_code = ec;
                                    }
                                }

                                // Strip the first line (command echo) for run mode.
                                var payload = msg.payload;
                                if (!detached and is_run_cmd and is_first_line) {
                                    if (std.mem.indexOfScalar(u8, payload, '\n')) |nl| {
                                        is_first_line = false;
                                        payload = payload[nl + 1 ..];
                                    } else {
                                        is_first_line = false;
                                        payload = payload[payload.len..]; // consume entire echo line
                                    }
                                }

                                if (payload.len > 0) {
                                    // Strip ANSI escape sequences to produce plain text.
                                    // This prevents shell prompts, colors, cursor movements,
                                    // and other VT sequences from corrupting the caller's terminal.
                                    const plain = util.stripAnsi(alloc, payload) catch |err| {
                                        std.log.warn("stripAnsi failed: {s}", .{@errorName(err)});
                                        continue;
                                    };
                                    defer alloc.free(plain);
                                    if (plain.len > 0) {
                                        try stdout_buf.appendSlice(alloc, plain);
                                    }
                                }
                            }
                        },
                        .TaskComplete => {
                            task_complete_code = if (msg.payload.len > 0) msg.payload[0] else 0;
                        },
                        else => {},
                    }
                }
            }
        }

        // Check for task completion after processing socket messages.
        // This must be outside the stdout write block because .TaskComplete
        // can arrive after all output has already been flushed, leaving
        // stdout_buf empty. Without this check, tail() would poll forever.
        if (task_complete_code) |exit_code| {
            // Flush any remaining output before returning
            flush_loop: while (stdout_buf.items.len > 0) {
                const n = lib_posix.write(lib_posix.STDOUT_FILENO, stdout_buf.items) catch |err| {
                    if (err == error.WouldBlock) break :flush_loop;
                    return err;
                };
                try stdout_buf.replaceRange(alloc, 0, n, &[_]u8{});
            }
            return exit_code;
        }

        if (stdout_buf.items.len > 0) {
            const n = lib_posix.write(lib_posix.STDOUT_FILENO, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (n > 0) {
                try stdout_buf.replaceRange(alloc, 0, n, &[_]u8{});
            }
        }

        // Check for HUP/ERR on any socket
        for (poll_fds.items) |poll_fd| {
            if (poll_fd.revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
                return 0;
            }
        }
    }
}

fn wait(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, matchers: std.ArrayList(socket.SessionMatch)) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Highest match count seen so far. Lets us distinguish "sessions haven't
    // appeared yet" (keep polling) from "sessions we were tracking
    // disappeared" (fail -- daemon crashed or was killed).
    var max_seen: i32 = 0;
    var zero_match_iters: u32 = 0;

    var agg_exit_code: u8 = 0;
    var last_print: std.Io.Timestamp = .zero;
    var prev_done: i32 = 0;
    while (true) {
        agg_exit_code = 0;
        var sessions = try util.get_session_entries(alloc, io, cfg.socket_dir);
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
                    .{
                        std.Io.Timestamp.now(io, .real).toSeconds(),
                        session.name,
                        session.error_name orelse "unknown",
                    },
                );
                try stderr.flush();
                agg_exit_code = 1;
                done += 1;
                continue;
            }
            if (session.task_ended_at == 0) {
                const now = std.Io.Timestamp.now(io, .real);
                if (now.toSeconds() - last_print.toSeconds() >= 5) {
                    try stdout.print(
                        "[{d}] waiting task={s}\n",
                        .{ now.toSeconds(), session.name },
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
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .real) catch unreachable;
    }

    if (agg_exit_code == 0) {
        try stdout.print("task(s) completed!\n", .{});
    } else {
        try stdout.print("task(s) failed!\n", .{});
    }
    try stdout.flush();

    const sessions = try util.get_session_entries(alloc, io, cfg.socket_dir);
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
            const history_text = fetchHistory(alloc, io, cfg, session.name) catch null;
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

fn list(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, short: bool) !void {
    const current_session = socket.getSeshNameFromEnv();
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    var sessions = try util.get_session_entries(alloc, io, cfg.socket_dir);
    defer {
        for (sessions.items) |session| {
            session.deinit(alloc);
        }
        sessions.deinit(alloc);
    }

    if (sessions.items.len == 0) {
        if (short) return;
        var errbuf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &errbuf);
        try stderr.interface.print("no sessions found in {s}\n", .{cfg.socket_dir});
        try stderr.interface.flush();
        return;
    }

    std.mem.sort(util.SessionEntry, sessions.items, {}, util.SessionEntry.lessThan);

    for (sessions.items) |session| {
        if (session.is_error) {
            try util.writeSessionLine(&stdout.interface, session, short, current_session);
            try stdout.interface.flush();
            continue;
        }

        try util.writeSessionLine(&stdout.interface, session, short, current_session);
        try stdout.interface.flush();
    }
}

fn detachAll(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg) !void {
    const session_name = socket.getSeshNameFromEnv();
    if (session_name.len == 0) {
        std.log.err("ZMX_SESSION env var not found: are you inside a zmx session?", .{});
        return;
    }
    std.log.info("detach all session={s}", .{session_name});

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(io, session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);
    const fd = ipc.connectSession(socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, session_name);
        return;
    };
    defer lib_posix.close(fd);
    ipc.send(fd, .DetachAll, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

fn kill(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, force: bool) !void {
    std.log.info("kill session={s}", .{session_name});
    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(io, session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const exists = try socket.sessionExists(io, dir, session_name);
    if (!exists) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        w.interface.print("error: session \"{s}\" does not exist\n", .{session_name}) catch {};
        w.interface.flush() catch {};
        return error.SessionNotFound;
    }
    const fd = ipc.connectSession(socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        if (force or err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(io, dir, session_name);
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

    defer lib_posix.close(fd);
    ipc.send(fd, .Kill, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    // Block until the daemon hangs up. The daemon's shutdown defer closes
    // and unlinks the listen socket before it closes client connections,
    // so by the time we read EOF here the session name is free for reuse
    // and a subsequent `zmx run <name>` can't land in the dying daemon's
    // accept backlog.
    var drain: [256]u8 = undefined;
    while (true) {
        const n = lib_posix.read(fd, &drain) catch break;
        if (n == 0) break;
    }

    var buf: [100]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("killed session {s}\n", .{session_name});
    try w.interface.flush();
}

fn printLabelError(io: std.Io, session_name: []const u8, err: anyerror) noreturn {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    switch (err) {
        error.Timeout => w.interface.print(
            "error: session \"{s}\" does not support labels (daemon too old?)\n",
            .{session_name},
        ) catch {},
        error.ConnectionRefused, error.Unexpected => w.interface.print(
            "error: session \"{s}\" not found or unresponsive\n",
            .{session_name},
        ) catch {},
        else => w.interface.print(
            "error: {s}\n",
            .{@errorName(err)},
        ) catch {},
    }
    w.interface.flush() catch {};
    std.process.exit(1);
}

fn labelGet(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, single_kv: []const u8) !void {
    std.log.info("label get session={s}", .{session_name});

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(io, session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    const payload = ipc.roundTripForTag(alloc, socket_path, .LabelGet, "", .LabelData) catch |err| {
        printLabelError(io, session_name, err);
    };
    defer alloc.free(payload);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    if (single_kv.len == 0) {
        try stdout.interface.print("{s}", .{payload});
        try stdout.interface.flush();
        return;
    }

    const val = try label.getLabelValueFromPairs(single_kv, payload);
    try stdout.interface.print("{s}", .{val});
    try stdout.interface.flush();
}

fn labelSet(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, labels: []const u8) !void {
    std.log.info("label set session={s}", .{session_name});

    var kvs = label.LabelIterator.init(labels);
    while (kvs.next()) |kv| {
        label.assertLabel(kv.key, kv.value) catch |err| {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writer(io, &buf);
            const msg = "error: key-value kvs can only contain [a-z, A-Z, 0-9, -_.] characters";
            switch (err) {
                error.LabelKeyEmpty => {
                    w.interface.print("error: label key cannot be empty\n", .{}) catch {};
                },
                error.LabelKeyReservedName => {
                    w.interface.print("error: \"{s}\" is a read-only built-in field\n", .{kv.key}) catch {};
                },
                error.LabelKeyInvalidChar => {
                    w.interface.print("{s}: key=[{s}]\n", .{ msg, kv.key }) catch {};
                },
                error.LabelValueInvalidChar => {
                    w.interface.print("{s}: value=[{s}]\n", .{ msg, kv.value }) catch {};
                },
            }
            w.interface.flush() catch {};
            std.process.exit(1);
        };
    }

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(io, session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    _ = ipc.roundTripForTag(alloc, socket_path, .LabelSet, labels, .Ack) catch |err| {
        printLabelError(io, session_name, err);
    };
}

fn labelClear(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8) !void {
    std.log.info("label clear session={s}", .{session_name});

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(io, session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    _ = ipc.roundTripForTag(alloc, socket_path, .LabelClear, "", .Ack) catch |err| {
        printLabelError(io, session_name, err);
    };
}

/// Fetch terminal history from a session socket, returning it as an allocated
/// string. Caller owns the returned memory and must free it.
fn fetchHistory(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *Cfg,
    session_name: []const u8,
) ![]const u8 {
    std.log.info("fetch history session={s}", .{session_name});
    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => {
            socket.printSessionNameTooLong(io, session_name, cfg.socket_dir);
            return error.NameTooLong;
        },
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const exists = try socket.sessionExists(io, dir, session_name);
    if (!exists) {
        return error.SessionNotFound;
    }

    const fd = ipc.connectSession(socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, session_name);
        return err;
    };
    defer lib_posix.close(fd);

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
        var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        const poll_result = lib_posix.poll(&poll_fds, 5000) catch return error.Timeout;
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

fn history(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, format: util.HistoryFormat) !void {
    std.log.info("history session={s}", .{session_name});

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(io, session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const exists = try socket.sessionExists(io, dir, session_name);
    if (!exists) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        w.interface.print("error: session \"{s}\" does not exist\n", .{session_name}) catch {};
        w.interface.flush() catch {};
        return error.SessionNotFound;
    }
    const fd = ipc.connectSession(socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, session_name);
        return;
    };
    defer lib_posix.close(fd);

    const format_byte = [_]u8{@intFromEnum(format)};
    ipc.send(fd, .History, &format_byte) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    while (true) {
        var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        const poll_result = lib_posix.poll(&poll_fds, 5000) catch return;
        if (poll_result == 0) {
            std.log.err("timeout waiting for history response", .{});
            return;
        }

        const n = sb.read(fd) catch return;
        if (n == 0) return;

        while (sb.next()) |msg| {
            if (msg.header.tag == .History) {
                _ = lib_posix.write(lib_posix.STDOUT_FILENO, msg.payload) catch return;
                return;
            }
        }
    }
}

fn switchSesh(gpa: std.mem.Allocator, io: std.Io, daemon: *Daemon, current_sesh: []const u8) !void {
    // we want daemon.session_name because that's the session name the user provided during zmx attach
    // instead of the name of the session they are currently inside of.
    const next_session = daemon.session_name;
    std.log.info("switch session cur={s} next={s}", .{ current_sesh, next_session });

    const socket_path = socket.getSocketPath(gpa, daemon.cfg.socket_dir, current_sesh) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(io, current_sesh, daemon.cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer gpa.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, daemon.cfg.socket_dir, .{});
    defer dir.close(io);

    const exists = try socket.sessionExists(io, dir, current_sesh);
    if (!exists) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        w.interface.print("error: session \"{s}\" does not exist\n", .{current_sesh}) catch {};
        w.interface.flush() catch {};
        return error.SessionNotFound;
    }
    const fd = ipc.connectSession(socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, current_sesh);
        return;
    };
    defer lib_posix.close(fd);

    ipc.send(fd, .Switch, next_session) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

fn attach(gpa: std.mem.Allocator, io: std.Io, daemon: *Daemon) !void {
    const sesh = socket.getSeshNameFromEnv();
    if (sesh.len > 0) {
        return switchSesh(gpa, io, daemon, sesh);
    }

    const is_daemon_proc = try daemon.ensureSession(io);
    if (is_daemon_proc) return;

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
    const stdin_is_tty = cross.c.tcgetattr(lib_posix.STDIN_FILENO, &orig_termios) == 0;

    defer {
        if (stdin_is_tty) {
            _ = cross.c.tcsetattr(lib_posix.STDIN_FILENO, cross.c.TCSAFLUSH, &orig_termios);
        }
        // Reset terminal modes on detach
        const restore_seq = "\x1bc";
        _ = lib_posix.write(lib_posix.STDOUT_FILENO, restore_seq) catch {};
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

        _ = cross.c.tcsetattr(lib_posix.STDIN_FILENO, cross.c.TCSANOW, &raw_termios);
    }

    // Clear screen before attaching. This provides a clean slate before
    // the session restore.
    const clear_seq = "\x1b[2J\x1b[H";
    _ = try lib_posix.write(lib_posix.STDOUT_FILENO, clear_seq);

    const looper = try loop.clientLoop(client_sock);
    switch (looper.kind) {
        .detach => return,
        .switch_session => {
            if (looper.session_name) |session_name| {
                // Reset terminal modes when switching sessions
                const restore_seq = "\x1bc";
                _ = lib_posix.write(lib_posix.STDOUT_FILENO, restore_seq) catch {};

                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
                const cwd = cwd_buf[0..cwd_len];
                const target_path = socket.getSocketPath(
                    gpa,
                    daemon.cfg.socket_dir,
                    session_name,
                ) catch |err| switch (err) {
                    error.NameTooLong => return socket.printSessionNameTooLong(
                        io,
                        session_name,
                        daemon.cfg.socket_dir,
                    ),
                    error.OutOfMemory => return err,
                };

                var target_daemon = Daemon.init(io, daemon.cfg, session_name, target_path);
                target_daemon.cwd = cwd;
                target_daemon.shell = daemon.shell;
                return attach(gpa, io, &target_daemon);
            }
        },
    }
}

fn writeFile(gpa: std.mem.Allocator, io: std.Io, daemon: *Daemon, file_path: []const u8) !void {
    const is_daemon_proc = try daemon.ensureSession(io);
    if (is_daemon_proc) return;

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);

    const stdin_fd = lib_posix.STDIN_FILENO;
    var stdin_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer stdin_buf.deinit(gpa);

    while (true) {
        var tmp: [4096]u8 = undefined;
        const n = lib_posix.read(stdin_fd, &tmp) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
        if (n == 0) break;
        try stdin_buf.appendSlice(gpa, tmp[0..n]);
    }

    const socket_path = socket.getSocketPath(
        gpa,
        daemon.cfg.socket_dir,
        daemon.session_name,
    ) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(
            io,
            daemon.session_name,
            daemon.cfg.socket_dir,
        ),
        error.OutOfMemory => return err,
    };
    var dir = try std.Io.Dir.openDirAbsolute(io, daemon.cfg.socket_dir, .{});
    defer dir.close(io);

    const result = ipc.probeSession(gpa, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(io, dir, daemon.session_name);
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

    defer result.deinit();

    // Build wire payload: [u32 path len][path bytes][file content]
    var wire_buf = try std.ArrayList(u8).initCapacity(
        gpa,
        @sizeOf(u32) + file_path.len + stdin_buf.items.len,
    );
    defer wire_buf.deinit(gpa);
    const path_len: u32 = @intCast(file_path.len);
    try wire_buf.appendSlice(gpa, std.mem.asBytes(&path_len));
    try wire_buf.appendSlice(gpa, file_path);
    try wire_buf.appendSlice(gpa, stdin_buf.items);

    ipc.send(result.fd, .Write, wire_buf.items) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(gpa);
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

fn send(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, socket_path: []const u8, text_parts: [][]const u8, tag: ipc.Tag) !void {
    std.log.info("send session={s}", .{session_name});
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(alloc);

    if (text_parts.len > 0) {
        for (text_parts, 0..) |part, i| {
            if (i > 0) try payload.append(alloc, ' ');
            try payload.appendSlice(alloc, part);
        }
    } else {
        // Read from stdin when no text arguments provided.
        const stdin_file = std.Io.File.stdin();
        defer stdin_file.close(io);
        var stdin_buf: [4096]u8 = undefined;
        var reader = stdin_file.reader(io, &stdin_buf);
        if (!try stdin_file.isTty(io)) {
            while (true) {
                var dest: [1024]u8 = undefined;
                const n = try reader.interface.readSliceShort(&dest);
                if (n == 0) break; // EOF
                try payload.appendSlice(alloc, dest[0..n]);
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

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const probe_result = ipc.probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(io, dir, session_name);
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
    defer probe_result.deinit();

    ipc.send(probe_result.fd, tag, payload.items) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };
}

fn run(gpa: std.mem.Allocator, io: std.Io, daemon: *Daemon, detached: bool, command_args: [][]const u8) !void {
    var cmd_to_send: ?[]const u8 = null;
    var allocated_cmd: ?[]u8 = null;
    defer if (allocated_cmd) |cmd| gpa.free(cmd);

    const is_daemon_proc = try daemon.ensureSession(io);
    if (is_daemon_proc) return;

    if (command_args.len > 0) {
        var cmd_list = std.ArrayList(u8).empty;
        defer cmd_list.deinit(gpa);

        for (command_args, 0..) |arg, i| {
            if (i > 0) try cmd_list.append(gpa, ' ');
            if (util.shellNeedsQuoting(arg)) {
                const quoted = try util.shellQuote(gpa, arg);
                defer gpa.free(quoted);
                try cmd_list.appendSlice(gpa, quoted);
            } else {
                try cmd_list.appendSlice(gpa, arg);
            }
        }

        // \r, not \n: once the shell is at the readline prompt the PTY is in
        // raw mode; readline's accept-line binds to CR. The first-ever run
        // works with \n only because it arrives during shell startup while
        // the line discipline is still canonical.
        try cmd_list.append(gpa, '\r');

        cmd_to_send = try cmd_list.toOwnedSlice(gpa);
        allocated_cmd = @constCast(cmd_to_send.?);
    } else {
        // Read from stdin when no text arguments provided.
        const stdin_file = std.Io.File.stdin();
        defer stdin_file.close(io);
        var stdin_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
        defer stdin_buf.deinit(gpa);
        var stdbuf: [4096]u8 = undefined;
        var reader = stdin_file.reader(io, &stdbuf);
        if (!try stdin_file.isTty(io)) {
            while (true) {
                var dest: [1024]u8 = undefined;
                const n = try reader.interface.readSliceShort(&dest);
                if (n == 0) break; // EOF
                try stdin_buf.appendSlice(gpa, dest[0..n]);
            }

            if (stdin_buf.items.len > 0) {
                // Normalize any trailing newline to CR so readline (raw mode)
                // accepts each line.
                if (stdin_buf.items[stdin_buf.items.len - 1] == '\n') {
                    stdin_buf.items[stdin_buf.items.len - 1] = '\r';
                } else {
                    try stdin_buf.append(gpa, '\r');
                }

                cmd_to_send = try gpa.dupe(u8, stdin_buf.items);
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
    defer lib_posix.close(client_sock);

    var fds = try std.ArrayList(i32).initCapacity(gpa, 1);
    defer fds.deinit(gpa);
    try fds.append(gpa, client_sock);

    ipc.send(client_sock, .Run, cmd_to_send.?) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };

    const exit_code = try tail(gpa, fds, detached, true);
    lib_posix.exit(exit_code);
}
