const std = @import("std");
const posix = std.posix;
const xevg = @import("xev");
const xev = xevg.Dynamic;
const socket_path = "/tmp/zmx.sock";

const c = @cImport({
    @cInclude("pty.h");
    @cInclude("utmp.h");
    @cInclude("stdlib.h");
});

// Generic JSON message structure used for parsing incoming protocol messages from clients
const Message = struct {
    type: []const u8,
    payload: std.json.Value,
};

// Request payload for attaching to a session
const AttachRequest = struct {
    session_name: []const u8,
};

// A PTY session that manages a persistent shell process
// Stores the PTY master file descriptor, shell process PID, scrollback buffer,
// and a read buffer for async I/O with libxev
const Session = struct {
    name: []const u8,
    pty_master_fd: std.posix.fd_t,
    buffer: std.ArrayList(u8),
    child_pid: std.posix.pid_t,
    allocator: std.mem.Allocator,
    pty_read_buffer: [4096]u8,
    created_at: i64,

    fn deinit(self: *Session) void {
        self.allocator.free(self.name);
        self.buffer.deinit(self.allocator);
    }
};

// A connected client that communicates with the daemon over a Unix socket
// Tracks the client's file descriptor, async stream for I/O, read buffer,
// and which session (if any) the client is currently attached to
const Client = struct {
    fd: std.posix.fd_t,
    stream: xev.Stream,
    read_buffer: [4096]u8,
    allocator: std.mem.Allocator,
    attached_session: ?[]const u8,
    server_ctx: *ServerContext,
};

// Main daemon server state that manages the event loop, Unix socket server,
// all active client connections, and all persistent PTY sessions
const ServerContext = struct {
    loop: *xev.Loop,
    server_fd: std.posix.fd_t,
    accept_completion: xev.Completion,
    clients: std.AutoHashMap(std.posix.fd_t, *Client),
    sessions: std.StringHashMap(*Session),
    allocator: std.mem.Allocator,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var thread_pool = xevg.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    std.debug.print("zmx daemon starting...\n", .{});

    _ = std.fs.cwd().deleteFile(socket_path) catch {};

    // AF.UNIX: Unix domain socket for local IPC with client processes
    // SOCK.STREAM: Reliable, bidirectional communication for JSON protocol messages
    // SOCK.NONBLOCK: Prevents blocking to work with libxev's async event loop
    const server_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    defer posix.close(server_fd);

    var unix_addr = std.net.Address.initUnix(socket_path) catch |err| {
        std.debug.print("initUnix failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try posix.bind(server_fd, &unix_addr.any, unix_addr.getOsSockLen());
    try posix.listen(server_fd, 128);

    var server_stream = xev.Stream.initFd(server_fd);
    var server_context = ServerContext{
        .loop = &loop,
        .server_fd = server_fd,
        .accept_completion = .{},
        .clients = std.AutoHashMap(std.posix.fd_t, *Client).init(allocator),
        .sessions = std.StringHashMap(*Session).init(allocator),
        .allocator = allocator,
    };
    defer server_context.clients.deinit();
    defer {
        var it = server_context.sessions.valueIterator();
        while (it.next()) |session| {
            session.*.deinit();
            allocator.destroy(session.*);
        }
        server_context.sessions.deinit();
    }

    server_stream.poll(
        &loop,
        &server_context.accept_completion,
        .read,
        ServerContext,
        &server_context,
        acceptCallback,
    );

    try loop.run(.until_done);
}

fn acceptCallback(
    ctx_opt: ?*ServerContext,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    poll_result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const ctx = ctx_opt.?;
    if (poll_result) |_| {
        while (true) {
            // SOCK.CLOEXEC: Close socket on exec to prevent child PTY processes from inheriting client connections
            // SOCK.NONBLOCK: Make client socket non-blocking for async I/O
            const client_fd = posix.accept(ctx.server_fd, null, null, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK) catch |err| {
                if (err == error.WouldBlock) {
                    // No more pending connections
                    break;
                }
                std.debug.print("accept failed: {s}\n", .{@errorName(err)});
                return .disarm; // Stop polling on error
            };

            const client = ctx.allocator.create(Client) catch @panic("failed to create client");
            client.* = .{
                .fd = client_fd,
                .stream = xev.Stream.initFd(client_fd),
                .read_buffer = undefined,
                .allocator = ctx.allocator,
                .attached_session = null,
                .server_ctx = ctx,
            };

            ctx.clients.put(client_fd, client) catch @panic("failed to add client");
            std.debug.print("new client connected fd={d}\n", .{client_fd});

            const read_completion = ctx.allocator.create(xev.Completion) catch @panic("failed to create completion");
            client.stream.read(ctx.loop, read_completion, .{ .slice = &client.read_buffer }, Client, client, readCallback);
        }
    } else |err| {
        std.debug.print("poll failed: {s}\n", .{@errorName(err)});
    }

    // Re-arm the poll
    return .rearm;
}

fn readCallback(
    client_opt: ?*Client,
    loop: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    read_buffer: xev.ReadBuffer,
    read_result: xev.ReadError!usize,
) xev.CallbackAction {
    _ = loop;
    const client = client_opt.?;
    if (read_result) |len| {
        if (len == 0) {
            return closeClient(client, completion);
        }
        const data = read_buffer.slice[0..len];
        handleMessage(client, data) catch |err| {
            std.debug.print("handleMessage failed: {s}\n", .{@errorName(err)});
            return closeClient(client, completion);
        };

        return .rearm;
    } else |err| {
        if (err == error.EndOfStream or err == error.EOF) {
            return closeClient(client, completion);
        }
        std.debug.print("read failed: {s}\n", .{@errorName(err)});
        return closeClient(client, completion);
    }
}

fn handleMessage(client: *Client, data: []const u8) !void {
    std.debug.print("Received message from client fd={d}: {s}", .{ client.fd, data });

    // Parse JSON message
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        client.allocator,
        data,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value.object;
    const msg_type = root.get("type").?.string;
    const payload = root.get("payload").?.object;

    if (std.mem.eql(u8, msg_type, "attach_session_request")) {
        const session_name = payload.get("session_name").?.string;
        std.debug.print("Handling attach request for session: {s}\n", .{session_name});
        try handleAttachSession(client.server_ctx, client, session_name);
    } else if (std.mem.eql(u8, msg_type, "detach_session_request")) {
        const session_name = payload.get("session_name").?.string;
        const target_client_fd = if (payload.get("client_fd")) |fd_value| fd_value.integer else null;
        std.debug.print("Handling detach request for session: {s}, target_fd: {any}\n", .{ session_name, target_client_fd });
        try handleDetachSession(client, session_name, target_client_fd);
    } else if (std.mem.eql(u8, msg_type, "kill_session_request")) {
        const session_name = payload.get("session_name").?.string;
        std.debug.print("Handling kill request for session: {s}\n", .{session_name});
        try handleKillSession(client, session_name);
    } else if (std.mem.eql(u8, msg_type, "list_sessions_request")) {
        std.debug.print("Handling list sessions request\n", .{});
        try handleListSessions(client.server_ctx, client);
    } else if (std.mem.eql(u8, msg_type, "pty_in")) {
        const text = payload.get("text").?.string;
        try handlePtyInput(client, text);
    } else {
        std.debug.print("Unknown message type: {s}\n", .{msg_type});
    }
}

fn handleDetachSession(client: *Client, session_name: []const u8, target_client_fd: ?i64) !void {
    const ctx = client.server_ctx;

    // Check if the session exists
    if (!ctx.sessions.contains(session_name)) {
        const error_response = try std.fmt.allocPrint(
            client.allocator,
            "{{\"type\":\"detach_session_response\",\"payload\":{{\"status\":\"error\",\"error_message\":\"Session not found: {s}\"}}}}\n",
            .{session_name},
        );
        defer client.allocator.free(error_response);

        _ = posix.write(client.fd, error_response) catch |err| {
            std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
            return err;
        };
        return;
    }

    // If target_client_fd is provided, find and detach that specific client
    if (target_client_fd) |target_fd| {
        const target_fd_cast: std.posix.fd_t = @intCast(target_fd);
        if (ctx.clients.get(target_fd_cast)) |target_client| {
            if (target_client.attached_session) |attached| {
                if (std.mem.eql(u8, attached, session_name)) {
                    target_client.attached_session = null;

                    // Send notification to the target client
                    const notification = "{\"type\":\"detach_notification\",\"payload\":{\"status\":\"ok\"}}\n";
                    _ = posix.write(target_client.fd, notification) catch |err| {
                        std.debug.print("Error notifying client fd={d}: {s}\n", .{ target_client.fd, @errorName(err) });
                    };

                    // Send response to the requesting client
                    const response = "{\"type\":\"detach_session_response\",\"payload\":{\"status\":\"ok\"}}\n";
                    std.debug.print("Detached client fd={d} from session: {s}\n", .{ target_fd_cast, session_name });

                    _ = posix.write(client.fd, response) catch |err| {
                        std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
                        return err;
                    };
                    return;
                } else {
                    const error_response = try std.fmt.allocPrint(
                        client.allocator,
                        "{{\"type\":\"detach_session_response\",\"payload\":{{\"status\":\"error\",\"error_message\":\"Target client not attached to session: {s}\"}}}}\n",
                        .{session_name},
                    );
                    defer client.allocator.free(error_response);

                    _ = posix.write(client.fd, error_response) catch |err| {
                        std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
                        return err;
                    };
                    return;
                }
            }
        }

        const error_response = try std.fmt.allocPrint(
            client.allocator,
            "{{\"type\":\"detach_session_response\",\"payload\":{{\"status\":\"error\",\"error_message\":\"Target client fd={d} not found\"}}}}\n",
            .{target_fd},
        );
        defer client.allocator.free(error_response);

        _ = posix.write(client.fd, error_response) catch |err| {
            std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
            return err;
        };
        return;
    }

    // No target_client_fd provided, check if requesting client is attached
    if (client.attached_session) |attached| {
        if (!std.mem.eql(u8, attached, session_name)) {
            const error_response = try std.fmt.allocPrint(
                client.allocator,
                "{{\"type\":\"detach_session_response\",\"payload\":{{\"status\":\"error\",\"error_message\":\"Not attached to session: {s}\"}}}}\n",
                .{session_name},
            );
            defer client.allocator.free(error_response);

            _ = posix.write(client.fd, error_response) catch |err| {
                std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
                return err;
            };
            return;
        }

        client.attached_session = null;
        const response = "{\"type\":\"detach_session_response\",\"payload\":{\"status\":\"ok\"}}\n";
        std.debug.print("Sending detach response to client fd={d}: {s}", .{ client.fd, response });

        _ = posix.write(client.fd, response) catch |err| {
            std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
            return err;
        };
    } else {
        const error_response = "{\"type\":\"detach_session_response\",\"payload\":{\"status\":\"error\",\"error_message\":\"Not attached to any session\"}}\n";
        _ = posix.write(client.fd, error_response) catch |err| {
            std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
            return err;
        };
    }
}

fn handleKillSession(client: *Client, session_name: []const u8) !void {
    const ctx = client.server_ctx;

    // Check if the session exists
    const session = ctx.sessions.get(session_name) orelse {
        const error_response = try std.fmt.allocPrint(
            client.allocator,
            "{{\"type\":\"kill_session_response\",\"payload\":{{\"status\":\"error\",\"error_message\":\"Session not found: {s}\"}}}}\n",
            .{session_name},
        );
        defer client.allocator.free(error_response);

        _ = posix.write(client.fd, error_response) catch |err| {
            std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
            return err;
        };
        return;
    };

    // Notify all attached clients to exit
    var client_it = ctx.clients.iterator();
    while (client_it.next()) |entry| {
        const attached_client = entry.value_ptr.*;
        if (attached_client.attached_session) |attached| {
            if (std.mem.eql(u8, attached, session_name)) {
                attached_client.attached_session = null;

                // Send kill notification to client
                const notification = "{\"type\":\"kill_notification\",\"payload\":{\"status\":\"ok\"}}\n";
                _ = posix.write(attached_client.fd, notification) catch |err| {
                    std.debug.print("Error notifying client fd={d}: {s}\n", .{ attached_client.fd, @errorName(err) });
                };
            }
        }
    }

    // Kill the PTY process
    const kill_result = posix.kill(session.child_pid, posix.SIG.TERM);
    if (kill_result) |_| {
        std.debug.print("Sent SIGTERM to PID {d}\n", .{session.child_pid});
    } else |err| {
        std.debug.print("Error killing PID {d}: {s}\n", .{ session.child_pid, @errorName(err) });
    }

    // Close PTY master fd
    posix.close(session.pty_master_fd);

    // Remove from sessions map BEFORE cleaning up (session.deinit frees session.name)
    _ = ctx.sessions.remove(session_name);

    // Clean up session
    session.deinit();
    ctx.allocator.destroy(session);

    // Send response to requesting client
    const response = "{\"type\":\"kill_session_response\",\"payload\":{\"status\":\"ok\"}}\n";
    std.debug.print("Killed session: {s}\n", .{session_name});

    _ = posix.write(client.fd, response) catch |err| {
        std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
        return err;
    };
}

fn handleListSessions(ctx: *ServerContext, client: *Client) !void {
    var response = try std.ArrayList(u8).initCapacity(client.allocator, 1024);
    defer response.deinit(client.allocator);

    try response.appendSlice(client.allocator, "{\"type\":\"list_sessions_response\",\"payload\":{\"status\":\"ok\",\"sessions\":[");

    var it = ctx.sessions.iterator();
    var first = true;
    while (it.next()) |entry| {
        const session = entry.value_ptr.*;

        if (!first) {
            try response.append(client.allocator, ',');
        }
        first = false;

        var clients_count: i64 = 0;
        var client_it = ctx.clients.iterator();
        while (client_it.next()) |client_entry| {
            const attached_client = client_entry.value_ptr.*;
            if (attached_client.attached_session) |attached| {
                if (std.mem.eql(u8, attached, session.name)) {
                    clients_count += 1;
                }
            }
        }

        const status = if (clients_count > 0) "attached" else "detached";

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(session.created_at) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        const session_json = try std.fmt.allocPrint(
            client.allocator,
            "{{\"name\":\"{s}\",\"status\":\"{s}\",\"clients\":{d},\"created_at\":\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\"}}",
            .{ session.name, status, clients_count, year_day.year, month_day.month.numeric(), month_day.day_index + 1, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute() },
        );
        defer client.allocator.free(session_json);

        try response.appendSlice(client.allocator, session_json);
    }

    try response.appendSlice(client.allocator, "]}}\n");

    std.debug.print("Sending list response to client fd={d}: {s}", .{ client.fd, response.items });

    const written = posix.write(client.fd, response.items) catch |err| {
        std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
        return err;
    };
    _ = written;
}

fn handleAttachSession(ctx: *ServerContext, client: *Client, session_name: []const u8) !void {
    // Check if session already exists
    if (ctx.sessions.get(session_name)) |session| {
        std.debug.print("Attaching to existing session: {s}\n", .{session_name});
        client.attached_session = session.name;
        try readFromPty(ctx, client, session);
        // TODO: Send scrollback buffer to client
        return;
    }

    // Create new session with forkpty
    std.debug.print("Creating new session: {s}\n", .{session_name});
    const session = try createSession(ctx.allocator, session_name);
    try ctx.sessions.put(session.name, session);
    client.attached_session = session.name;
    try readFromPty(ctx, client, session);
}

fn handlePtyInput(client: *Client, text: []const u8) !void {
    const session_name = client.attached_session orelse {
        std.debug.print("Client fd={d} not attached to any session\n", .{client.fd});
        return error.NotAttached;
    };

    const session = client.server_ctx.sessions.get(session_name) orelse {
        std.debug.print("Session {s} not found\n", .{session_name});
        return error.SessionNotFound;
    };

    std.debug.print("Writing {d} bytes to PTY fd={d}\n", .{ text.len, session.pty_master_fd });

    // Write input to PTY master fd
    const written = posix.write(session.pty_master_fd, text) catch |err| {
        std.debug.print("Error writing to PTY: {s}\n", .{@errorName(err)});
        return err;
    };
    _ = written;
}

fn readFromPty(ctx: *ServerContext, client: *Client, session: *Session) !void {
    _ = ctx;
    const stream = xev.Stream.initFd(session.pty_master_fd);
    const read_compl = client.allocator.create(xev.Completion) catch @panic("failed to create completion");
    stream.read(
        client.server_ctx.loop,
        read_compl,
        .{ .slice = &session.pty_read_buffer },
        Client,
        client,
        readPtyCallback,
    );

    const response = try std.fmt.allocPrint(
        client.allocator,
        "{{\"type\":\"attach_session_response\",\"payload\":{{\"status\":\"ok\",\"client_fd\":{d}}}}}\n",
        .{client.fd},
    );
    defer client.allocator.free(response);

    std.debug.print("Sending response to client fd={d}: {s}", .{ client.fd, response });

    const written = posix.write(client.fd, response) catch |err| {
        std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
        return err;
    };
    _ = written;
}

fn readPtyCallback(
    client_opt: ?*Client,
    loop: *xev.Loop,
    completion: *xev.Completion,
    stream: xev.Stream,
    read_buffer: xev.ReadBuffer,
    read_result: xev.ReadError!usize,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = stream;
    const client = client_opt.?;

    if (read_result) |bytes_read| {
        if (bytes_read == 0) {
            std.debug.print("pty closed\n", .{});
            return .disarm;
        }

        const data = read_buffer.slice[0..bytes_read];
        std.debug.print("PTY output ({d} bytes)\n", .{bytes_read});

        // Build JSON response with properly escaped text
        var response_buf = std.ArrayList(u8).initCapacity(client.allocator, 4096) catch return .disarm;
        defer response_buf.deinit(client.allocator);

        response_buf.appendSlice(client.allocator, "{\"type\":\"pty_out\",\"payload\":{\"text\":\"") catch return .disarm;

        // Manually escape JSON special characters
        for (data) |byte| {
            switch (byte) {
                '"' => response_buf.appendSlice(client.allocator, "\\\"") catch return .disarm,
                '\\' => response_buf.appendSlice(client.allocator, "\\\\") catch return .disarm,
                '\n' => response_buf.appendSlice(client.allocator, "\\n") catch return .disarm,
                '\r' => response_buf.appendSlice(client.allocator, "\\r") catch return .disarm,
                '\t' => response_buf.appendSlice(client.allocator, "\\t") catch return .disarm,
                0x08 => response_buf.appendSlice(client.allocator, "\\b") catch return .disarm,
                0x0C => response_buf.appendSlice(client.allocator, "\\f") catch return .disarm,
                0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F...0xFF => {
                    const escaped = std.fmt.allocPrint(client.allocator, "\\u{x:0>4}", .{byte}) catch return .disarm;
                    defer client.allocator.free(escaped);
                    response_buf.appendSlice(client.allocator, escaped) catch return .disarm;
                },
                else => response_buf.append(client.allocator, byte) catch return .disarm,
            }
        }

        response_buf.appendSlice(client.allocator, "\"}}\n") catch return .disarm;

        const response = response_buf.items;
        std.debug.print("Sending response to client fd={d}\n", .{client.fd});

        // Send synchronously for now (blocking write)
        const written = posix.write(client.fd, response) catch |err| {
            std.debug.print("Error writing to fd={d}: {s}", .{ client.fd, @errorName(err) });
            return .disarm;
        };
        _ = written;

        return .rearm;
    } else |err| {
        std.debug.print("PTY read error: {s}\n", .{@errorName(err)});
        return .disarm;
    }
    unreachable;
}

fn execShellWithPrompt(allocator: std.mem.Allocator, session_name: []const u8, shell: [*:0]const u8) noreturn {
    // Detect shell type and add prompt injection
    const shell_name = std.fs.path.basename(std.mem.span(shell));

    if (std.mem.eql(u8, shell_name, "fish")) {
        // Fish: wrap the existing fish_prompt function
        const init_cmd = std.fmt.allocPrint(allocator, "if test -e ~/.config/fish/config.fish; source ~/.config/fish/config.fish; end; " ++
            "functions -q fish_prompt; and functions -c fish_prompt _zmx_original_prompt; " ++
            "function fish_prompt; echo -n '[{s}] '; _zmx_original_prompt; end\x00", .{session_name}) catch {
            std.posix.exit(1);
        };
        const argv = [_:null]?[*:0]const u8{ shell, "--init-command".ptr, @ptrCast(init_cmd.ptr), null };
        const err = std.posix.execveZ(shell, &argv, std.c.environ);
        std.debug.print("execve failed: {s}\n", .{@errorName(err)});
        std.posix.exit(1);
    } else if (std.mem.eql(u8, shell_name, "bash")) {
        // Bash: prepend to PS1 via bashrc injection
        const bashrc = std.fmt.allocPrint(allocator, "[ -f ~/.bashrc ] && source ~/.bashrc; PS1='[{s}] '$PS1\x00", .{session_name}) catch {
            std.posix.exit(1);
        };
        const argv = [_:null]?[*:0]const u8{ shell, "--rcfile".ptr, "/dev/stdin".ptr, null };
        // Note: This approach doesn't work well. Let's use PROMPT_COMMAND instead
        const argv2 = [_:null]?[*:0]const u8{ shell, "--init-file".ptr, @ptrCast(bashrc.ptr), null };
        _ = argv2;
        const err = std.posix.execveZ(shell, &argv, std.c.environ);
        std.debug.print("execve failed: {s}\n", .{@errorName(err)});
        std.posix.exit(1);
    } else if (std.mem.eql(u8, shell_name, "zsh")) {
        // Zsh: prepend to PROMPT after loading zshrc
        const zdotdir = std.posix.getenv("ZDOTDIR") orelse std.posix.getenv("HOME") orelse "/tmp";
        const zshrc = std.fmt.allocPrint(allocator, "[ -f {s}/.zshrc ] && source {s}/.zshrc; PROMPT='[{s}] '$PROMPT\x00", .{ zdotdir, zdotdir, session_name }) catch {
            std.posix.exit(1);
        };
        _ = zshrc;
        // For zsh, just set the environment variable and let it prepend
        const prompt_var = std.fmt.allocPrint(allocator, "PROMPT=[{s}] ${{PROMPT:-'%# '}}\x00", .{session_name}) catch {
            std.posix.exit(1);
        };
        _ = c.putenv(@ptrCast(prompt_var.ptr));
        const argv = [_:null]?[*:0]const u8{ shell, null };
        const err = std.posix.execveZ(shell, &argv, std.c.environ);
        std.debug.print("execve failed: {s}\n", .{@errorName(err)});
        std.posix.exit(1);
    } else {
        // Default: just run the shell
        const argv = [_:null]?[*:0]const u8{ shell, null };
        const err = std.posix.execveZ(shell, &argv, std.c.environ);
        std.debug.print("execve failed: {s}\n", .{@errorName(err)});
        std.posix.exit(1);
    }
}

fn createSession(allocator: std.mem.Allocator, session_name: []const u8) !*Session {
    var master_fd: c_int = undefined;

    // Fork and create PTY
    const pid = c.forkpty(&master_fd, null, null, null);
    if (pid < 0) {
        return error.ForkPtyFailed;
    }

    if (pid == 0) {
        // Child process - set environment and execute shell with prompt
        const zmx_session_var = std.fmt.allocPrint(allocator, "ZMX_SESSION={s}\x00", .{session_name}) catch {
            std.posix.exit(1);
        };
        _ = c.putenv(@ptrCast(zmx_session_var.ptr));

        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        execShellWithPrompt(allocator, session_name, shell);
    }

    // Parent process - setup session
    std.debug.print("✓ Created PTY session: name={s}, master_fd={d}, child_pid={d}\n", .{
        session_name,
        master_fd,
        pid,
    });

    // Make PTY master fd non-blocking for async I/O
    const flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(master_fd, posix.F.SETFL, flags | @as(u32, 0o4000));

    const session = try allocator.create(Session);
    session.* = .{
        .name = try allocator.dupe(u8, session_name),
        .pty_master_fd = @intCast(master_fd),
        .buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
        .child_pid = pid,
        .allocator = allocator,
        .pty_read_buffer = undefined,
        .created_at = std.time.timestamp(),
    };

    return session;
}

fn closeClient(client: *Client, completion: *xev.Completion) xev.CallbackAction {
    std.debug.print("Closing client fd={d}\n", .{client.fd});

    // Remove client from the clients map
    _ = client.server_ctx.clients.remove(client.fd);

    // Initiate async close of the client stream
    const close_completion = client.allocator.create(xev.Completion) catch {
        // If we can't allocate, just clean up synchronously
        posix.close(client.fd);
        client.allocator.destroy(completion);
        client.allocator.destroy(client);
        return .disarm;
    };

    client.stream.close(client.server_ctx.loop, close_completion, Client, client, closeCallback);
    client.allocator.destroy(completion);
    return .disarm;
}

fn closeCallback(
    client_opt: ?*Client,
    _: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    close_result: xev.CloseError!void,
) xev.CallbackAction {
    const client = client_opt.?;
    if (close_result) |_| {} else |err| {
        std.debug.print("close failed: {s}\n", .{@errorName(err)});
    }
    std.debug.print("client disconnected fd={d}\n", .{client.fd});
    client.allocator.destroy(completion);
    client.allocator.destroy(client);
    return .disarm;
}
