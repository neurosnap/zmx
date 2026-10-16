const std = @import("std");
const zmx = @import("lib.zig");
const Environ = std.process.Environ;
const build_options = @import("build_options");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const completions = @import("completions.zig");
const util = @import("util.zig");
const socket = @import("socket.zig");
const label = @import("label.zig");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const Cfg = @import("cfg.zig");
const version = build_options.version;
const ghostty_version = build_options.ghostty_version;

pub const std_options: std.Options = .{
    .logFn = log.zmxLogFn,
    .log_level = .debug,
};

fn detectHelp(arg: []const u8) bool {
    return (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"));
}

/// Prints an error message to stderr and exits with status 1.
fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("error: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}
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
        const sesh_name = args.next() orelse {
            return printError(io, "session name required (or run inside a zmx session)", .{});
        };
        if (detectHelp(sesh_name)) return help(io);
        const sesh = try socket.resolveSessionOrEnv(gpa, io, sesh_name);
        defer gpa.free(sesh);
        const single_kv = args.next() orelse "";
        return labelGet(gpa, io, &cfg, sesh, single_kv);
    } else if (std.mem.eql(u8, cmd, "set")) {
        const sesh_name = args.next() orelse {
            return printError(io, "session name required (or run inside a zmx session)", .{});
        };
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
        if (kvs.items.len == 0) {
            return printError(io, "at least one key=value pair required", .{});
        }
        return labelSet(gpa, io, &cfg, sesh, kvs.items);
    } else if (std.mem.eql(u8, cmd, "clear") or std.mem.eql(u8, cmd, "cl")) {
        const sesh_name = args.next() orelse {
            return printError(io, "session name required (or run inside a zmx session)", .{});
        };
        if (detectHelp(sesh_name)) return help(io);
        const sesh = try socket.resolveSessionOrEnv(gpa, io, sesh_name);
        defer gpa.free(sesh);
        return labelClear(gpa, io, &cfg, sesh);
    } else if (std.mem.eql(u8, cmd, "completions") or std.mem.eql(u8, cmd, "c")) {
        const arg = args.next() orelse {
            return printError(io, "completions requires a shell argument (bash, zsh, fish, nu, yash)", .{});
        };
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return help(io);
        }
        const shell = completions.Shell.fromString(arg) orelse {
            return printError(io, "unknown shell \"{s}\" (valid: bash, zsh, fish, nu, yash)", .{arg});
        };
        return printCompletions(io, shell);
    } else if (std.mem.eql(u8, cmd, "detach") or std.mem.eql(u8, cmd, "d")) {
        return detachAll(gpa, io, &cfg);
    } else if (std.mem.eql(u8, cmd, "history") or std.mem.eql(u8, cmd, "hi")) {
        var session_name: ?[]const u8 = null;
        var format: util.HistoryFormat = .plain;
        var scrollback_rows: ?u32 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return help(io);
            } else if (std.mem.eql(u8, arg, "--vt")) {
                format = .vt;
            } else if (std.mem.eql(u8, arg, "--html")) {
                format = .html;
            } else if (std.mem.eql(u8, arg, "--screen")) {
                if (scrollback_rows != null) return printError(io, "--screen and --scrollback may only be specified once", .{});
                scrollback_rows = 0;
            } else if (std.mem.eql(u8, arg, "--scrollback")) {
                if (scrollback_rows != null) return printError(io, "--screen and --scrollback may only be specified once", .{});
                const count = args.next() orelse return printError(io, "--scrollback requires a row count", .{});
                scrollback_rows = std.fmt.parseInt(u32, count, 10) catch return printError(io, "invalid scrollback row count: {s}", .{count});
            } else if (session_name == null) {
                session_name = arg;
            }
        }
        const sesh_env = socket.getSeshNameFromEnv();
        const raw_name = session_name orelse (if (sesh_env.len > 0) sesh_env else {
            return printError(io, "session name required (or run inside a zmx session)", .{});
        });
        const sesh = try socket.getSeshName(gpa, raw_name);
        defer gpa.free(sesh);
        return history(gpa, io, &cfg, sesh, format, scrollback_rows);
    } else if (std.mem.eql(u8, cmd, "attach") or std.mem.eql(u8, cmd, "a")) {
        var attach_args: std.ArrayList([]const u8) = .empty;
        defer attach_args.deinit(gpa);
        while (args.next()) |arg| {
            try attach_args.append(gpa, arg);
        }

        const parsed = parseAttachArgs(attach_args.items);
        if (parsed.want_help) {
            return help(io);
        }
        if (parsed.missing_labels_value) {
            return printError(io, "--labels requires \"key=value ...\"", .{});
        }
        // Before ensureSession, so a rejected label does not leave a session
        // behind that the caller never asked for.
        if (parsed.labels) |kvs| assertLabels(io, kvs);

        var command: ?[][]const u8 = null;
        if (parsed.command_start < attach_args.items.len) {
            command = attach_args.items[parsed.command_start..];
        }

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const cwd = cwd_buf[0..cwd_len];

        const env_keys = lib_posix.getenv("ZMX_TRACK_ENV") orelse cfg.tracked_envs;
        const env_str = try getTrackedEnvStr(gpa, env_keys, init.environ_map);
        defer gpa.free(env_str);

        zmx.attach(gpa, io, parsed.session_name, .{
            .command = command,
            .cwd = cwd,
            .shell = shell_env,
            .labels = parsed.labels,
            .tracked_env = env_str,
        }) catch |err| {
            return printError(io, "cannot connect to session \"{s}\": {s}", .{ parsed.session_name, @errorName(err) });
        };
        return;
    } else if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "r")) {
        const session_name = args.next() orelse "";
        if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
            return help(io);
        }

        var cmd_args_raw: std.ArrayList([]const u8) = .empty;
        defer cmd_args_raw.deinit(gpa);
        var detached = false;
        while (args.next()) |arg| {
            // Once the command has started, -d belongs to the command.
            if (cmd_args_raw.items.len == 0 and std.mem.startsWith(u8, arg, "-d")) {
                detached = true;
            } else {
                try cmd_args_raw.append(gpa, arg);
            }
        }

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const cwd = cwd_buf[0..cwd_len];

        var stdin_bytes: ?[]const u8 = null;
        var stdin_buf = std.ArrayList(u8).empty;
        defer stdin_buf.deinit(gpa);

        if (cmd_args_raw.items.len == 0) {
            const stdin_file = std.Io.File.stdin();
            defer stdin_file.close(io);
            var stdbuf: [4096]u8 = undefined;
            var reader = stdin_file.reader(io, &stdbuf);
            if (!try stdin_file.isTty(io)) {
                while (true) {
                    var dest: [1024]u8 = undefined;
                    const n = try reader.interface.readSliceShort(&dest);
                    if (n == 0) break;
                    try stdin_buf.appendSlice(gpa, dest[0..n]);
                }
                if (stdin_buf.items.len > 0) {
                    stdin_bytes = stdin_buf.items;
                }
            }
        }

        if (cmd_args_raw.items.len == 0 and stdin_bytes == null) {
            return printError(io, "run requires a command (or pipe input via stdin)", .{});
        }

        const exit_code = zmx.run(gpa, io, session_name, cmd_args_raw.items, .{
            .detached = detached,
            .cwd = cwd,
            .shell = shell_env,
            .stdin_bytes = stdin_bytes,
        }) catch |err| switch (err) {
            error.CommandRequired => return printError(io, "run requires a command (or pipe input via stdin)", .{}),
            else => return printError(io, "session not ready: {s}", .{@errorName(err)}),
        };
        lib_posix.exit(exit_code);
    } else if (std.mem.eql(u8, cmd, "send") or std.mem.eql(u8, cmd, "s")) {
        const session_name = args.next() orelse "";
        if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
            return help(io);
        }
        if (session_name.len == 0) {
            return printError(io, "session name required", .{});
        }

        var text_parts: std.ArrayList([]const u8) = .empty;
        defer text_parts.deinit(gpa);
        while (args.next()) |arg| {
            try text_parts.append(gpa, arg);
        }

        send(gpa, io, session_name, text_parts.items, .Send) catch |err| {
            if (err == error.SessionUnresponsive) std.process.exit(1);
            return printError(io, "send failed: {s}", .{@errorName(err)});
        };
    } else if (std.mem.eql(u8, cmd, "print") or std.mem.eql(u8, cmd, "p")) {
        const session_name = args.next() orelse "";
        if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
            return help(io);
        }
        if (session_name.len == 0) {
            return printError(io, "session name required", .{});
        }

        var text_parts: std.ArrayList([]const u8) = .empty;
        defer text_parts.deinit(gpa);
        while (args.next()) |arg| {
            try text_parts.append(gpa, arg);
        }

        send(gpa, io, session_name, text_parts.items, .Output) catch |err| {
            if (err == error.SessionUnresponsive) std.process.exit(1);
            return printError(io, "print failed: {s}", .{@errorName(err)});
        };
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
            return printError(io, "session name required", .{});
        }
        const sessions = try zmx.list(gpa, io);
        defer {
            for (sessions) |session| {
                session.deinit(gpa);
            }
            gpa.free(sessions);
        }

        var killed_any = false;
        for (sessions) |session| {
            for (matchers.items) |m| {
                if (!m.matches(session.name)) continue;
                kill(gpa, io, &cfg, session.name, force) catch |err| {
                    if (err == error.SessionNotFound and force) {
                        killed_any = true;
                        continue;
                    }
                    try stderr.print("failed to kill session={s}: {s}\n", .{ session.name, @errorName(err) });
                    try stderr.flush();
                };
                killed_any = true;
                break;
            }
        }
        if (!killed_any) {
            for (matchers.items) |m| {
                if (m.is_prefix) continue;
                kill(gpa, io, &cfg, m.name, force) catch |err| {
                    if (err == error.SessionNotFound and force) {
                        killed_any = true;
                        continue;
                    }
                    return printError(io, "failed to kill session={s}: {s}", .{ m.name, @errorName(err) });
                };
                killed_any = true;
            }
            if (!killed_any) return printError(io, "no matching sessions found", .{});
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
            return printError(io, "session name required", .{});
        }
        return wait(gpa, io, &cfg, matchers);
    } else if (std.mem.eql(u8, cmd, "tail") or std.mem.eql(u8, cmd, "t")) {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        while (args.next()) |session_name| {
            if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
                return help(io);
            }
            try names.append(gpa, session_name);
        }
        if (names.items.len == 0) {
            return printError(io, "session name required", .{});
        }
        _ = zmx.tail(gpa, io, names.items, null) catch |err| switch (err) {
            error.SessionNotFound => return printError(io, "no matching sessions found", .{}),
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "write") or std.mem.eql(u8, cmd, "wr")) {
        const session_name = args.next() orelse "";
        if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
            return help(io);
        }
        if (session_name.len == 0) {
            return printError(io, "session name required", .{});
        }
        const file_path = args.next() orelse "";
        if (std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h")) {
            return help(io);
        }
        if (file_path.len == 0) {
            return printError(io, "file path required", .{});
        }

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const cwd = cwd_buf[0..cwd_len];

        writeFile(gpa, io, session_name, file_path, cwd, shell_env) catch |err| {
            if (err == error.SessionUnresponsive) std.process.exit(1);
            return printError(io, "write failed: {s}", .{@errorName(err)});
        };
    } else if (std.mem.eql(u8, cmd, "print-env")) {
        var shell_mode = false;
        var session_name: ?[]const u8 = null;
        var single_kv: []const u8 = "";

        while (args.next()) |arg| {
            if (detectHelp(arg)) return help(io);
            if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--shell")) {
                shell_mode = true;
            } else if (session_name == null) {
                session_name = arg;
            } else if (single_kv.len == 0) {
                single_kv = arg;
            }
        }

        const sesh_arg = session_name orelse {
            return printError(io, "session name required (or run inside a zmx session)", .{});
        };
        const sesh = try socket.resolveSessionOrEnv(gpa, io, sesh_arg);
        defer gpa.free(sesh);
        return envGet(gpa, io, &cfg, sesh, single_kv, shell_mode);
    } else {
        return printError(io, "unknown command \"{s}\"", .{cmd});
    }
}

fn help(io: std.Io) !void {
    const help_text =
        \\zmx - session persistence for terminal processes
        \\
        \\Usage: zmx <command> [args...]
        \\
        \\Commands:
        \\  [a]ttach [--labels kv] <name> [command...]                 Attach to session, creating if needed
        \\  [r]un <name> [-d] [command...]                             Send command without attaching
        \\  [s]end <name> <text...>                                    Send raw input to session PTY
        \\  [p]rint <name> <text...>                                   Inject text into session display
        \\  [wr]ite <name> <file_path>                                 Write stdin to file_path through the session
        \\  [d]etach                                                   Detach all clients (ctrl+\\ for current client)
        \\  [l]ist|ls [--short]                                        List active sessions
        \\  [g]et <name>                                               Get session labels
        \\  set <name> k=v ...                                         Set session labels (k= to remove)
        \\  [cl]ear <name>                                             Clear all session labels
        \\  print-env [-s] <name> [key]                                Print tracked environment variables
        \\  [k]ill <name>... [--force]                                 Kill session and all attached clients
        \\  [hi]story <name> [--vt|--html] [--screen|--scrollback]     Output session scrollback
        \\  [w]ait <name>...                                           Wait for session tasks to complete
        \\  [t]ail <name>...                                           Follow session output
        \\  [c]ompletions <shell>                                      Shell completions (bash, zsh, fish, nu, yash)
        \\  [v]ersion                                                  Show version and metadata (socket dir, log dir)
        \\  [h]elp                                                     Show this help
        \\
        \\Attach:
        \\  This will spawn a login $SHELL with a PTY.  You can provide a
        \\  command instead of creating a shell.
        \\
        \\  --labels applies labels as the session is created, in the same form
        \\  `zmx set` takes. A caller that creates and then labels in two steps
        \\  leaves an unlabelled session behind if it dies between them.
        \\
        \\  Examples:
        \\    zmx attach dev
        \\    zmx attach dev vim
        \\    zmx attach --labels "project=api role=worker" build
        \\
        \\History:
        \\  This should generally be used with `tail` to print the last lines
        \\  of the session's scrollback history.
        \\
        \\  --screen outputs only the active screen, and --scrollback N adds up
        \\  to N rows of scrollback above it, so pollers can skip formatting
        \\  history they would discard. Both work with --vt and --html.
        \\
        \\  Examples:
        \\    zmx history <session> | tail -100
        \\    zmx history --screen <session>
        \\    zmx history --scrollback 512 <session>
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
        \\    zmx run dev -d sleep 10
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
        \\Print-env:
        \\  Print tracked environment variables for the leader client of a session.
        \\
        \\  Flags:
        \\    -s, --shell       Output POSIX export/unset commands for eval
        \\
        \\  Examples:
        \\    zmx print-env .
        \\    zmx print-env -s .
        \\    zmx print-env dev
        \\    zmx print-env dev DISPLAY
        \\    eval "$(zmx print-env -s .)"    # inside shell session precmd hook
        \\
        \\Environment variables:
        \\  SHELL                Default shell for new sessions
        \\  ZMX_DIR              Socket directory (priority 1)
        \\  XDG_RUNTIME_DIR      Socket directory (priority 2)
        \\  TMPDIR               Socket directory (priority 3)
        \\  ZMX_SESSION          Session name (injected automatically; makes attach
        \\                       switch this session)
        \\  ZMX_SESSION_PREFIX   Prefix added to all session names
        \\  ZMX_TRACK_ENV        Comma-separated list of environment variables to track
        \\                       from attaching clients
        \\  ZMX_DIR_MODE         Sets mode for socket and log directories (octal, defaults to 0750)
        \\  ZMX_LOG_MODE         Sets mode for log files (octal, defaults to 0640)
        \\  ZMX_NO_DETACH_KEY    Disables the ctrl+\ detach shortcut (set to any value)
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

fn wait(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, matchers: std.ArrayList(socket.SessionMatch)) !void {
    _ = cfg;
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
        const sessions = try zmx.list(alloc, io);
        defer {
            for (sessions) |session| {
                session.deinit(alloc);
            }
            alloc.free(sessions);
        }
        var total: i32 = 0;
        var done: i32 = 0;

        for (sessions) |session| {
            var found = false;
            for (matchers.items) |m| {
                if (m.matches(session.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;

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

    const sessions = try zmx.list(alloc, io);
    defer {
        for (sessions) |session| {
            session.deinit(alloc);
        }
        alloc.free(sessions);
    }
    for (sessions) |session| {
        var found = false;
        for (matchers.items) |m| {
            if (m.matches(session.name)) {
                found = true;
                break;
            }
        }
        if (!found) continue;
        if (session.task_exit_code.? > 0) {
            try stdout.print("---\n", .{});
            try stdout.print("[{d}] failed task={s} exit_status={d}\n", .{
                session.task_ended_at.?,
                session.name,
                session.task_exit_code.?,
            });

            // Fetch and print the last 20 lines of history for debugging
            const history_lines: usize = 20;
            const history_text = zmx.history(alloc, io, session.name, .plain) catch null;
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
    const sessions = try zmx.list(alloc, io);
    defer {
        for (sessions) |session| {
            session.deinit(alloc);
        }
        alloc.free(sessions);
    }

    if (sessions.len == 0) {
        if (short) return;
        var errbuf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &errbuf);
        try stderr.interface.print("no sessions found in {s}\n", .{cfg.socket_dir});
        try stderr.interface.flush();
        return;
    }

    std.mem.sort(util.SessionEntry, sessions, {}, util.SessionEntry.lessThan);

    for (sessions) |session| {
        try util.writeSessionLine(&stdout.interface, session, short, current_session);
        try stdout.interface.flush();
    }
}

fn detachAll(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg) !void {
    _ = cfg;
    const session_name = socket.getSeshNameFromEnv();
    if (session_name.len == 0) {
        return printError(io, "not inside a zmx session (ZMX_SESSION not set)", .{});
    }
    std.log.info("detach all session={s}", .{session_name});
    zmx.detach(alloc, io, session_name) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

fn kill(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, force: bool) !void {
    _ = cfg;
    std.log.info("kill session={s}", .{session_name});
    const status = zmx.kill(alloc, io, session_name, .{ .force = force }) catch |err| switch (err) {
        error.SessionNotFound => return error.SessionNotFound,
        error.SessionUnresponsive => return error.SessionUnresponsive,
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    if (status == .cleaned_stale) {
        var ebuf: [4096]u8 = undefined;
        var ew = std.Io.File.stderr().writer(io, &ebuf);
        ew.interface.print("cleaned up stale session {s}\n", .{session_name}) catch {};
        ew.interface.flush() catch {};
        return;
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
    _ = cfg;
    std.log.info("label get session={s}", .{session_name});

    const key = if (single_kv.len == 0) null else single_kv;
    const val = zmx.get(alloc, io, session_name, key) catch |err| {
        if (err == error.LabelKeyNotFound) {
            return printError(io, "label key \"{s}\" not found in session \"{s}\"", .{ single_kv, session_name });
        }
        printLabelError(io, session_name, err);
    };
    defer alloc.free(val);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.print("{s}", .{val});
    try stdout.interface.flush();
}

/// Rejects a malformed label set before the caller acts on it. Exits rather
/// than returning, so `attach --labels` can check its labels before a session
/// exists to be left behind.
fn assertLabels(io: std.Io, labels: []const u8) void {
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
}

fn getTrackedEnvStr(
    alloc: std.mem.Allocator,
    env_keys: []const u8,
    env_map: *const std.process.Environ.Map,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var iter = std.mem.splitScalar(u8, env_keys, ',');
    while (iter.next()) |entry| {
        const env = std.mem.trim(u8, entry, " \t\r\n");
        if (env.len == 0) continue;
        if (env_map.get(env)) |val| {
            try out.appendSlice(alloc, env);
            try out.append(alloc, '=');
            try out.appendSlice(alloc, val);
            try out.append(alloc, '\n');
        } else {
            try out.append(alloc, '-');
            try out.appendSlice(alloc, env);
            try out.append(alloc, '\n');
        }
    }

    return out.toOwnedSlice(alloc);
}

pub const EnvEntry = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const EnvIterator = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn init(payload: []const u8) EnvIterator {
        return .{ .it = std.mem.splitScalar(u8, payload, '\n') };
    }

    pub fn next(self: *EnvIterator) ?EnvEntry {
        while (self.it.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] == '-') {
                return .{ .key = line[1..], .value = null };
            } else if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
                return .{ .key = line[0..eq_idx], .value = line[eq_idx + 1 ..] };
            }
        }
        return null;
    }
};

fn getEnvValue(key: []const u8, payload: []const u8) error{EnvVarNotFound}![]const u8 {
    var it = EnvIterator.init(payload);
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            return entry.value orelse return error.EnvVarNotFound;
        }
    }
    return error.EnvVarNotFound;
}

fn printEnvError(io: std.Io, session_name: []const u8, err: anyerror) noreturn {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    switch (err) {
        error.SessionNotFound => w.interface.print("error: session \"{s}\" not found\n", .{session_name}) catch {},
        error.DaemonUnresponsive => w.interface.print("error: session \"{s}\" daemon unresponsive\n", .{session_name}) catch {},
        error.EnvVarNotFound => w.interface.print("error: environment variable not found\n", .{}) catch {},
        else => w.interface.print(
            "error: could not communicate with session \"{s}\" err={s}\n",
            .{ session_name, @errorName(err) },
        ) catch {},
    }
    w.interface.flush() catch {};
    std.process.exit(1);
}

fn envGet(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, single_kv: []const u8, shell_mode: bool) !void {
    _ = cfg;
    std.log.info("env get session={s}", .{session_name});

    const key = if (single_kv.len > 0) single_kv else null;
    const payload = zmx.printEnv(alloc, io, session_name, key) catch |err| {
        printEnvError(io, session_name, err);
    };
    defer alloc.free(payload);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    if (single_kv.len > 0) {
        try stdout.interface.print("{s}\n", .{payload});
        try stdout.interface.flush();
        return;
    }

    if (payload.len == 0) return;

    if (shell_mode) {
        var it = EnvIterator.init(payload);
        while (it.next()) |entry| {
            if (entry.value) |val| {
                try stdout.interface.print("export {s}='", .{entry.key});
                for (val) |c| {
                    if (c == '\'') {
                        try stdout.interface.print("'\\''", .{});
                    } else {
                        try stdout.interface.print("{c}", .{c});
                    }
                }
                try stdout.interface.print("';\n", .{});
            } else {
                try stdout.interface.print("unset {s};\n", .{entry.key});
            }
        }
    } else {
        try stdout.interface.print("{s}", .{payload});
    }
    try stdout.interface.flush();
}

fn labelSet(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, labels: []const u8) !void {
    _ = cfg;
    std.log.info("label set session={s}", .{session_name});

    assertLabels(io, labels);
    zmx.set(alloc, io, session_name, labels) catch |err| {
        printLabelError(io, session_name, err);
    };
}

fn labelClear(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8) !void {
    _ = cfg;
    std.log.info("label clear session={s}", .{session_name});

    zmx.clear(alloc, io, session_name) catch |err| {
        printLabelError(io, session_name, err);
    };
}

fn history(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, format: util.HistoryFormat, scrollback_rows: ?u32) !void {
    _ = cfg;
    std.log.info("history session={s}", .{session_name});

    const data = zmx.historyRange(alloc, io, session_name, format, scrollback_rows) catch |err| switch (err) {
        error.SessionNotFound => return printError(io, "session \"{s}\" does not exist", .{session_name}),
        error.SessionUnresponsive => return printError(io, "session \"{s}\" is unresponsive (SessionUnresponsive)", .{session_name}),
        error.CaptureNotSupported => return printError(io, "session \"{s}\" does not support --screen/--scrollback (daemon too old?)", .{session_name}),
        error.Timeout => {
            std.log.err("timeout waiting for history response", .{});
            return;
        },
        error.ConnectionClosed, error.ReadFailed => return,
        else => return err,
    };
    defer alloc.free(data);

    _ = lib_posix.write(lib_posix.STDOUT_FILENO, data) catch return;
}


const AttachArgs = struct {
    /// Session name, or "" when the caller did not name one.
    session_name: []const u8 = "",
    /// Index of the first word of the session command.
    command_start: usize = 0,
    /// `--labels "k=v ..."`: labels to apply once the session exists, in the
    /// same space-separated form `zmx set` takes.
    labels: ?[]const u8 = null,
    want_help: bool = false,
    /// `--labels` was given with nothing to apply.
    missing_labels_value: bool = false,
};

/// Parses the arguments that follow `zmx attach`. Flags are only recognized
/// before the session name, so everything after it stays part of the command
/// handed to the session.
fn parseAttachArgs(argv: []const []const u8) AttachArgs {
    const labels_flag = "--labels";
    var parsed: AttachArgs = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            parsed.want_help = true;
            return parsed;
        }
        if (std.mem.startsWith(u8, arg, labels_flag ++ "=")) {
            parsed.labels = arg[labels_flag.len + 1 ..];
            continue;
        }
        if (std.mem.eql(u8, arg, labels_flag)) {
            if (i + 1 >= argv.len) {
                parsed.missing_labels_value = true;
                parsed.command_start = argv.len;
                return parsed;
            }
            i += 1;
            parsed.labels = argv[i];
            continue;
        }
        parsed.session_name = arg;
        i += 1;
        break;
    }
    parsed.command_start = i;
    return parsed;
}


fn writeFile(gpa: std.mem.Allocator, io: std.Io, session_name: []const u8, file_path: []const u8, cwd: []const u8, shell: ?[]const u8) !void {
    _ = try zmx.create(gpa, io, session_name, .{ .cwd = cwd, .shell = shell });

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

    zmx.write(gpa, io, session_name, file_path, stdin_buf.items) catch |err| {
        if (err == error.SessionUnresponsive) {
            var errbuf: [4096]u8 = undefined;
            var ew = std.Io.File.stderr().writer(io, &errbuf);
            ew.interface.print("session {s} is unresponsive\ndaemon may be busy: try again\n", .{session_name}) catch {};
            ew.interface.flush() catch {};
            return error.SessionUnresponsive;
        }
        return err;
    };

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("file created {s}\n", .{file_path});
    try w.interface.flush();
}

fn send(alloc: std.mem.Allocator, io: std.Io, session_name: []const u8, text_parts: [][]const u8, tag: ipc.Tag) !void {
    std.log.info("send session={s}", .{session_name});

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

    if (payload.items.len == 0) {
        return printError(io, "text argument required (or pipe input via stdin)", .{});
    }

    const res = switch (tag) {
        .Send => zmx.send(alloc, io, session_name, payload.items),
        .Output => zmx.print(alloc, io, session_name, payload.items),
        else => unreachable,
    };
    res catch |err| {
        if (err == error.SessionUnresponsive) {
            var errbuf: [4096]u8 = undefined;
            var ew = std.Io.File.stderr().writer(io, &errbuf);
            ew.interface.print("session {s} is unresponsive\ndaemon may be busy: try again\n", .{session_name}) catch {};
            ew.interface.flush() catch {};
            return error.SessionUnresponsive;
        }
        return err;
    };
}

test "parseAttachArgs reads a bare session name" {
    const parsed = parseAttachArgs(&.{"dev"});
    try std.testing.expectEqualStrings("dev", parsed.session_name);
    try std.testing.expect(!parsed.want_help);
    try std.testing.expectEqual(@as(usize, 1), parsed.command_start);
}

test "parseAttachArgs keeps the session command intact" {
    const argv: []const []const u8 = &.{ "dev", "vim", "-n" };
    const parsed = parseAttachArgs(argv);
    try std.testing.expectEqualStrings("dev", parsed.session_name);
    // -n after the session name belongs to the command, not to zmx.
    try std.testing.expectEqualSlices([]const u8, argv[1..], argv[parsed.command_start..]);
}

test "parseAttachArgs reports help before the session name" {
    try std.testing.expect(parseAttachArgs(&.{"--help"}).want_help);
    try std.testing.expect(parseAttachArgs(&.{"-h"}).want_help);
    try std.testing.expect(parseAttachArgs(&.{ "--labels", "a=1", "--help" }).want_help);
    // Once a session name is read, -h belongs to the command.
    try std.testing.expect(!parseAttachArgs(&.{ "dev", "-h" }).want_help);
}

test "parseAttachArgs reads --labels in both forms" {
    for ([_][]const []const u8{
        &.{ "--labels", "a=1 b=2", "build" },
        &.{ "--labels=a=1 b=2", "build" },
    }) |argv| {
        const parsed = parseAttachArgs(argv);
        try std.testing.expectEqualStrings("a=1 b=2", parsed.labels.?);
        try std.testing.expectEqualStrings("build", parsed.session_name);
        try std.testing.expect(!parsed.missing_labels_value);
        try std.testing.expectEqual(argv.len, parsed.command_start);
    }
}

test "parseAttachArgs combines --labels with a session command" {
    const argv: []const []const u8 = &.{ "--labels", "a=1", "build", "make", "--labels" };
    const parsed = parseAttachArgs(argv);
    try std.testing.expectEqualStrings("a=1", parsed.labels.?);
    try std.testing.expectEqualStrings("build", parsed.session_name);
    // --labels after the session name belongs to the command.
    try std.testing.expectEqualSlices([]const u8, argv[3..], argv[parsed.command_start..]);
}

test "parseAttachArgs reports --labels with no value" {
    const parsed = parseAttachArgs(&.{"--labels"});
    try std.testing.expect(parsed.missing_labels_value);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.labels);
}

test "parseAttachArgs leaves labels unset when the flag is absent" {
    const parsed = parseAttachArgs(&.{"dev"});
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.labels);
    try std.testing.expect(!parsed.missing_labels_value);
}

test "getTrackedEnvStr includes set and unset entries" {
    const alloc = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();

    try env_map.put("DISPLAY", ":1");
    try env_map.put("SSH_AUTH_SOCK", "/tmp/ssh.sock");

    const str = try getTrackedEnvStr(alloc, "DISPLAY, KITTY_WINDOW_ID, SSH_AUTH_SOCK", &env_map);
    defer alloc.free(str);

    try std.testing.expectEqualStrings("DISPLAY=:1\n-KITTY_WINDOW_ID\nSSH_AUTH_SOCK=/tmp/ssh.sock\n", str);
}

test "getEnvValue extracts set value or returns EnvVarNotFound for unset" {
    const payload = "DISPLAY=:1\n-KITTY_WINDOW_ID\nSSH_AUTH_SOCK=/tmp/ssh.sock\n";

    try std.testing.expectEqualStrings(":1", try getEnvValue("DISPLAY", payload));
    try std.testing.expectEqualStrings("/tmp/ssh.sock", try getEnvValue("SSH_AUTH_SOCK", payload));
    try std.testing.expectError(error.EnvVarNotFound, getEnvValue("KITTY_WINDOW_ID", payload));
    try std.testing.expectError(error.EnvVarNotFound, getEnvValue("NONEXISTENT", payload));
}

test "EnvIterator parses set and unset entries correctly" {
    const payload = "DISPLAY=:1\n-KITTY_WINDOW_ID\nSSH_AUTH_SOCK=/tmp/ssh.sock\n";
    var it = EnvIterator.init(payload);

    const e1 = it.next().?;
    try std.testing.expectEqualStrings("DISPLAY", e1.key);
    try std.testing.expectEqualStrings(":1", e1.value.?);

    const e2 = it.next().?;
    try std.testing.expectEqualStrings("KITTY_WINDOW_ID", e2.key);
    try std.testing.expect(e2.value == null);

    const e3 = it.next().?;
    try std.testing.expectEqualStrings("SSH_AUTH_SOCK", e3.key);
    try std.testing.expectEqualStrings("/tmp/ssh.sock", e3.value.?);

    try std.testing.expect(it.next() == null);
}
