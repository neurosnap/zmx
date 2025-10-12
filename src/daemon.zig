const std = @import("std");
const posix = std.posix;
const xevg = @import("xev");
const xev = xevg.Dynamic;
const clap = @import("clap");
const config_mod = @import("config.zig");
const protocol = @import("protocol.zig");
const builtin = @import("builtin");

const ghostty = @import("ghostty-vt");

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

// Handler for processing VT sequences
const VTHandler = struct {
    terminal: *ghostty.Terminal,

    pub fn print(self: *VTHandler, cp: u21) !void {
        try self.terminal.print(cp);
    }
};

// Context for PTY read callbacks
const PtyReadContext = struct {
    session: *Session,
    server_ctx: *ServerContext,
};

// Context for PTY write callbacks
const PtyWriteContext = struct {
    allocator: std.mem.Allocator,
    message: []u8,
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

    // Terminal emulator state for session restore
    vt: ghostty.Terminal,
    vt_stream: ghostty.Stream(*VTHandler),
    vt_handler: VTHandler,
    attached_clients: std.AutoHashMap(std.posix.fd_t, void),

    // Buffer for incomplete UTF-8 sequences from previous read
    utf8_partial: [3]u8,
    utf8_partial_len: usize,

    fn deinit(self: *Session) void {
        self.allocator.free(self.name);
        self.buffer.deinit(self.allocator);
        self.vt.deinit(self.allocator);
        self.vt_stream.deinit();
        self.attached_clients.deinit();
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
    message_buffer: std.ArrayList(u8),
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

const params = clap.parseParamsComptime(
    \\-s, --socket-path <str>  Path to the Unix socket file
    \\
);

pub fn main(config: config_mod.Config, iter: *std.process.ArgIterator) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        var buf: [1024]u8 = undefined;
        var stderr_file = std.fs.File{ .handle = posix.STDERR_FILENO };
        var writer = stderr_file.writer(&buf);
        diag.report(&writer.interface, err) catch {};
        writer.interface.flush() catch {};
        return err;
    };
    defer res.deinit();

    const socket_path = res.args.@"socket-path" orelse config.socket_path;

    var thread_pool = xevg.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    std.debug.print("zmx daemon starting...\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  socket_path: {s}\n", .{socket_path});

    _ = std.fs.cwd().deleteFile(socket_path) catch {};

    // AF.UNIX: Unix domain socket for local IPC with client processes
    // SOCK.STREAM: Reliable, bidirectional communication for JSON protocol messages
    // SOCK.NONBLOCK: Prevents blocking to work with libxev's async event loop
    const server_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    defer {
        posix.close(server_fd);
        std.fs.cwd().deleteFile(socket_path) catch {};
    }

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
            const message_buffer = std.ArrayList(u8).initCapacity(ctx.allocator, 512) catch @panic("failed to create message buffer");
            client.* = .{
                .fd = client_fd,
                .stream = xev.Stream.initFd(client_fd),
                .read_buffer = undefined,
                .allocator = ctx.allocator,
                .attached_session = null,
                .server_ctx = ctx,
                .message_buffer = message_buffer,
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

        // Append to message buffer
        client.message_buffer.appendSlice(client.allocator, data) catch {
            return closeClient(client, completion);
        };

        // Process complete messages (delimited by newline)
        while (std.mem.indexOf(u8, client.message_buffer.items, "\n")) |newline_pos| {
            const message = client.message_buffer.items[0..newline_pos];
            handleMessage(client, message) catch |err| {
                std.debug.print("handleMessage failed: {s}\n", .{@errorName(err)});
                return closeClient(client, completion);
            };

            // Remove processed message from buffer (including newline)
            const remaining = client.message_buffer.items[newline_pos + 1 ..];
            const remaining_copy = client.allocator.dupe(u8, remaining) catch {
                return closeClient(client, completion);
            };
            client.message_buffer.clearRetainingCapacity();
            client.message_buffer.appendSlice(client.allocator, remaining_copy) catch {
                client.allocator.free(remaining_copy);
                return closeClient(client, completion);
            };
            client.allocator.free(remaining_copy);
        }

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

    // Parse message type first for dispatching
    const type_parsed = try protocol.parseMessageType(client.allocator, data);
    defer type_parsed.deinit();

    const msg_type = protocol.MessageType.fromString(type_parsed.value.type) orelse {
        std.debug.print("Unknown message type: {s}\n", .{type_parsed.value.type});
        return;
    };

    switch (msg_type) {
        .attach_session_request => {
            const parsed = try protocol.parseMessage(protocol.AttachSessionRequest, client.allocator, data);
            defer parsed.deinit();
            std.debug.print("Handling attach request for session: {s}\n", .{parsed.value.payload.session_name});
            try handleAttachSession(client.server_ctx, client, parsed.value.payload.session_name);
        },
        .detach_session_request => {
            const parsed = try protocol.parseMessage(protocol.DetachSessionRequest, client.allocator, data);
            defer parsed.deinit();
            std.debug.print("Handling detach request for session: {s}, target_fd: {any}\n", .{ parsed.value.payload.session_name, parsed.value.payload.client_fd });
            try handleDetachSession(client, parsed.value.payload.session_name, parsed.value.payload.client_fd);
        },
        .kill_session_request => {
            const parsed = try protocol.parseMessage(protocol.KillSessionRequest, client.allocator, data);
            defer parsed.deinit();
            std.debug.print("Handling kill request for session: {s}\n", .{parsed.value.payload.session_name});
            try handleKillSession(client, parsed.value.payload.session_name);
        },
        .list_sessions_request => {
            std.debug.print("Handling list sessions request\n", .{});
            try handleListSessions(client.server_ctx, client);
        },
        .pty_in => {
            const parsed = try protocol.parseMessage(protocol.PtyInput, client.allocator, data);
            defer parsed.deinit();
            try handlePtyInput(client, parsed.value.payload.text);
        },
        .window_resize => {
            const parsed = try protocol.parseMessage(protocol.WindowResize, client.allocator, data);
            defer parsed.deinit();
            try handleWindowResize(client, parsed.value.payload.rows, parsed.value.payload.cols);
        },
        else => {
            std.debug.print("Unexpected message type: {s}\n", .{type_parsed.value.type});
        },
    }
}

fn handleDetachSession(client: *Client, session_name: []const u8, target_client_fd: ?i64) !void {
    const ctx = client.server_ctx;

    // Check if the session exists
    const session = ctx.sessions.get(session_name) orelse {
        const error_msg = try std.fmt.allocPrint(client.allocator, "Session not found: {s}", .{session_name});
        defer client.allocator.free(error_msg);
        try protocol.writeJson(client.allocator, client.fd, .detach_session_response, protocol.DetachSessionResponse{
            .status = "error",
            .error_message = error_msg,
        });
        return;
    };

    // If target_client_fd is provided, find and detach that specific client
    if (target_client_fd) |target_fd| {
        const target_fd_cast: std.posix.fd_t = @intCast(target_fd);
        if (ctx.clients.get(target_fd_cast)) |target_client| {
            if (target_client.attached_session) |attached| {
                if (std.mem.eql(u8, attached, session_name)) {
                    target_client.attached_session = null;
                    _ = session.attached_clients.remove(target_fd_cast);

                    // Send notification to the target client
                    protocol.writeJson(target_client.allocator, target_client.fd, .detach_notification, protocol.DetachNotification{
                        .session_name = session_name,
                    }) catch |err| {
                        std.debug.print("Error notifying client fd={d}: {s}\n", .{ target_client.fd, @errorName(err) });
                    };

                    std.debug.print("Detached client fd={d} from session: {s}\n", .{ target_fd_cast, session_name });

                    // Send response to the requesting client
                    try protocol.writeJson(client.allocator, client.fd, .detach_session_response, protocol.DetachSessionResponse{
                        .status = "ok",
                    });
                    return;
                } else {
                    const error_msg = try std.fmt.allocPrint(client.allocator, "Target client not attached to session: {s}", .{session_name});
                    defer client.allocator.free(error_msg);
                    try protocol.writeJson(client.allocator, client.fd, .detach_session_response, protocol.DetachSessionResponse{
                        .status = "error",
                        .error_message = error_msg,
                    });
                    return;
                }
            }
        }

        const error_msg = try std.fmt.allocPrint(client.allocator, "Target client fd={d} not found", .{target_fd});
        defer client.allocator.free(error_msg);
        try protocol.writeJson(client.allocator, client.fd, .detach_session_response, protocol.DetachSessionResponse{
            .status = "error",
            .error_message = error_msg,
        });
        return;
    }

    // No target_client_fd provided, check if requesting client is attached
    if (client.attached_session) |attached| {
        if (!std.mem.eql(u8, attached, session_name)) {
            const error_msg = try std.fmt.allocPrint(client.allocator, "Not attached to session: {s}", .{session_name});
            defer client.allocator.free(error_msg);
            try protocol.writeJson(client.allocator, client.fd, .detach_session_response, protocol.DetachSessionResponse{
                .status = "error",
                .error_message = error_msg,
            });
            return;
        }

        client.attached_session = null;
        _ = session.attached_clients.remove(client.fd);

        std.debug.print("Sending detach response to client fd={d}\n", .{client.fd});
        try protocol.writeJson(client.allocator, client.fd, .detach_session_response, protocol.DetachSessionResponse{
            .status = "ok",
        });
    } else {
        try protocol.writeJson(client.allocator, client.fd, .detach_session_response, protocol.DetachSessionResponse{
            .status = "error",
            .error_message = "Not attached to any session",
        });
    }
}

fn handleKillSession(client: *Client, session_name: []const u8) !void {
    const ctx = client.server_ctx;

    // Check if the session exists
    const session = ctx.sessions.get(session_name) orelse {
        const error_msg = try std.fmt.allocPrint(client.allocator, "Session not found: {s}", .{session_name});
        defer client.allocator.free(error_msg);
        try protocol.writeJson(client.allocator, client.fd, .kill_session_response, protocol.KillSessionResponse{
            .status = "error",
            .error_message = error_msg,
        });
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
                protocol.writeJson(attached_client.allocator, attached_client.fd, .kill_notification, protocol.KillNotification{
                    .session_name = session_name,
                }) catch |err| {
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
    std.debug.print("Killed session: {s}\n", .{session_name});
    try protocol.writeJson(client.allocator, client.fd, .kill_session_response, protocol.KillSessionResponse{
        .status = "ok",
    });
}

fn handleListSessions(ctx: *ServerContext, client: *Client) !void {
    // TODO: Refactor to use protocol.writeJson() once we have a better approach for dynamic arrays
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
    const is_reattach = ctx.sessions.contains(session_name);
    const session = if (is_reattach) blk: {
        std.debug.print("Attaching to existing session: {s}\n", .{session_name});
        break :blk ctx.sessions.get(session_name).?;
    } else blk: {
        // Create new session with forkpty
        std.debug.print("Creating new session: {s}\n", .{session_name});
        const new_session = try createSession(ctx.allocator, session_name);
        try ctx.sessions.put(new_session.name, new_session);
        break :blk new_session;
    };

    // Mark client as attached
    client.attached_session = session.name;
    try session.attached_clients.put(client.fd, {});

    // Start reading from PTY if not already started (first client)
    if (session.attached_clients.count() == 1) {
        try readFromPty(ctx, client, session);

        // For first attach to new session, clear the client's terminal
        if (!is_reattach) {
            try protocol.writeJson(ctx.allocator, client.fd, .pty_out, protocol.PtyOutput{
                .text = "\x1b[2J\x1b[H", // Clear screen and move cursor to home
            });
        }
    } else {
        // Send attach success response for additional clients
        try protocol.writeJson(ctx.allocator, client.fd, .attach_session_response, protocol.AttachSessionResponse{
            .status = "ok",
            .client_fd = client.fd,
        });
    }

    // If reattaching, send the scrollback buffer (raw PTY output with colors)
    // Limit to last 64KB to avoid huge JSON messages
    if (is_reattach and session.buffer.items.len > 0) {
        std.debug.print("Sending scrollback buffer: {d} bytes total\n", .{session.buffer.items.len});

        const max_buffer_size = 64 * 1024;
        const buffer_start = if (session.buffer.items.len > max_buffer_size)
            session.buffer.items.len - max_buffer_size
        else
            0;
        const buffer_slice = session.buffer.items[buffer_start..];

        std.debug.print("Sending slice: {d} bytes (from offset {d})\n", .{ buffer_slice.len, buffer_start });

        try protocol.writeJson(ctx.allocator, client.fd, .pty_out, protocol.PtyOutput{
            .text = buffer_slice,
        });
        std.debug.print("Sent scrollback buffer to client fd={d}\n", .{client.fd});
    }
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

fn handleWindowResize(client: *Client, rows: u16, cols: u16) !void {
    const session_name = client.attached_session orelse {
        std.debug.print("Client fd={d} not attached to any session\n", .{client.fd});
        return error.NotAttached;
    };

    const session = client.server_ctx.sessions.get(session_name) orelse {
        std.debug.print("Session {s} not found\n", .{session_name});
        return error.SessionNotFound;
    };

    std.debug.print("Resizing session {s} to {d}x{d}\n", .{ session_name, cols, rows });

    // Update libghostty-vt terminal size
    try session.vt.resize(session.allocator, cols, rows);

    // Update PTY window size
    var ws = c.struct_winsize{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    const result = c.ioctl(session.pty_master_fd, c.TIOCSWINSZ, &ws);
    if (result < 0) {
        return error.IoctlFailed;
    }
}

fn readFromPty(ctx: *ServerContext, client: *Client, session: *Session) !void {
    const stream = xev.Stream.initFd(session.pty_master_fd);
    const read_compl = client.allocator.create(xev.Completion) catch @panic("failed to create completion");
    const pty_ctx = client.allocator.create(PtyReadContext) catch @panic("failed to create PTY context");
    pty_ctx.* = .{
        .session = session,
        .server_ctx = ctx,
    };
    stream.read(
        ctx.loop,
        read_compl,
        .{ .slice = &session.pty_read_buffer },
        PtyReadContext,
        pty_ctx,
        readPtyCallback,
    );

    std.debug.print("Sending attach response to client fd={d}\n", .{client.fd});

    try protocol.writeJson(client.allocator, client.fd, .attach_session_response, protocol.AttachSessionResponse{
        .status = "ok",
        .client_fd = client.fd,
    });
}

fn getSessionForClient(ctx: *ServerContext, client: *Client) ?*Session {
    const session_name = client.attached_session orelse return null;
    return ctx.sessions.get(session_name);
}

fn renderTerminalSnapshot(session: *Session, allocator: std.mem.Allocator) ![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, 4096);
    errdefer output.deinit(allocator);

    // Clear screen and move to home
    try output.appendSlice(allocator, "\x1b[2J\x1b[H");

    // Get the active screen from the terminal
    const screen = &session.vt.screen;
    const rows = screen.pages.rows;
    const cols = screen.pages.cols;

    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            // Build a point.Point referring to the active (visible) page
            const pt: ghostty.point.Point = .{ .active = .{
                .x = @as(u16, @intCast(col)),
                .y = @as(u16, @intCast(row)),
            } };

            if (screen.pages.getCell(pt)) |cell_ref| {
                const cp = cell_ref.cell.content.codepoint;
                if (cp == 0) {
                    try output.append(allocator, ' ');
                } else {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch 0;
                    if (len == 0) {
                        try output.append(allocator, ' ');
                    } else {
                        try output.appendSlice(allocator, buf[0..len]);
                    }
                }
            } else {
                // Outside bounds or no cell => space to preserve width
                try output.append(allocator, ' ');
            }
        }

        if (row < rows - 1) {
            try output.appendSlice(allocator, "\r\n");
        }
    }

    // Position cursor at correct location (ANSI is 1-based)
    const cursor = screen.cursor;
    try output.writer(allocator).print("\x1b[{d};{d}H", .{ cursor.y + 1, cursor.x + 1 });

    return output.toOwnedSlice(allocator);
}

fn notifyAttachedClientsAndCleanup(session: *Session, ctx: *ServerContext, reason: []const u8) void {
    std.debug.print("Session '{s}' ending: {s}\n", .{ session.name, reason });

    // Copy the session name before cleanup since HashMap key points to session.name
    const session_name = ctx.allocator.dupe(u8, session.name) catch {
        // Fallback: just use the existing name and skip removal if allocation fails
        std.debug.print("Failed to allocate session name copy\n", .{});
        posix.close(session.pty_master_fd);
        session.deinit();
        ctx.allocator.destroy(session);
        return;
    };
    defer ctx.allocator.free(session_name);

    // Notify all attached clients
    var it = session.attached_clients.keyIterator();
    while (it.next()) |client_fd| {
        const client = ctx.clients.get(client_fd.*) orelse continue;
        protocol.writeJson(
            client.allocator,
            client.fd,
            .kill_notification,
            protocol.KillNotification{ .session_name = session_name },
        ) catch |err| {
            std.debug.print("Failed to notify client {d}: {s}\n", .{ client_fd.*, @errorName(err) });
        };
        // Clear client's attached session reference (just null it, don't free - it points to session.name)
        client.attached_session = null;
    }

    // Close PTY master fd
    posix.close(session.pty_master_fd);

    // Remove from sessions map BEFORE session.deinit frees the key
    _ = ctx.sessions.remove(session_name);

    // Clean up session
    session.deinit();
    ctx.allocator.destroy(session);
}

fn readPtyCallback(
    pty_ctx_opt: ?*PtyReadContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    stream: xev.Stream,
    read_buffer: xev.ReadBuffer,
    read_result: xev.ReadError!usize,
) xev.CallbackAction {
    const pty_ctx = pty_ctx_opt.?;
    const session = pty_ctx.session;
    const ctx = pty_ctx.server_ctx;

    if (read_result) |bytes_read| {
        if (bytes_read == 0) {
            std.debug.print("PTY closed (EOF)\n", .{});
            notifyAttachedClientsAndCleanup(session, ctx, "PTY closed");
            ctx.allocator.destroy(pty_ctx);
            ctx.allocator.destroy(completion);
            return .disarm;
        }

        // Combine any partial UTF-8 from previous read with new data
        var combined_buf: [4096 + 3]u8 = undefined;
        const total_len = session.utf8_partial_len + bytes_read;

        if (session.utf8_partial_len > 0) {
            @memcpy(combined_buf[0..session.utf8_partial_len], session.utf8_partial[0..session.utf8_partial_len]);
            @memcpy(combined_buf[session.utf8_partial_len..total_len], read_buffer.slice[0..bytes_read]);
        } else {
            @memcpy(combined_buf[0..bytes_read], read_buffer.slice[0..bytes_read]);
        }

        const data = combined_buf[0..total_len];
        std.debug.print("PTY output ({d} bytes, {d} from partial)\n", .{ bytes_read, session.utf8_partial_len });

        // Check for incomplete UTF-8 sequence at end
        var valid_len = total_len;
        session.utf8_partial_len = 0;

        if (total_len > 0) {
            // Scan backwards to find if we have a partial UTF-8 sequence
            var i = total_len;
            const scan_start = if (total_len >= 4) total_len - 4 else 0;
            while (i > 0 and i > scan_start) {
                i -= 1;
                const byte = data[i];
                // Check if this is a UTF-8 start byte
                if (byte & 0x80 == 0) break; // ASCII, we're good
                if (byte & 0xC0 == 0xC0) {
                    // This is a UTF-8 start byte, check if sequence is complete
                    const expected_len: usize = if (byte & 0xE0 == 0xC0) 2 else if (byte & 0xF0 == 0xE0) 3 else if (byte & 0xF8 == 0xF0) 4 else 1;
                    if (i + expected_len > total_len) {
                        // Save partial sequence for next read
                        session.utf8_partial_len = total_len - i;
                        @memcpy(session.utf8_partial[0..session.utf8_partial_len], data[i..total_len]);
                        valid_len = i;
                    }
                    break;
                }
            }
        }

        const valid_data = data[0..valid_len];

        // Store PTY output in buffer for session restore
        session.buffer.appendSlice(session.allocator, valid_data) catch |err| {
            std.debug.print("Buffer append error: {s}\n", .{@errorName(err)});
        };

        // ALWAYS parse through libghostty-vt to maintain state
        session.vt_stream.nextSlice(valid_data) catch |err| {
            std.debug.print("VT parse error: {s}\n", .{@errorName(err)});
        };

        // Only proxy to clients if someone is attached
        if (session.attached_clients.count() > 0 and valid_len > 0) {
            // Build JSON response with properly escaped text
            var response_buf = std.ArrayList(u8).initCapacity(session.allocator, 4096) catch return .disarm;
            defer response_buf.deinit(session.allocator);

            response_buf.appendSlice(session.allocator, "{\"type\":\"pty_out\",\"payload\":{\"text\":\"") catch return .disarm;

            // Escape JSON special characters while preserving UTF-8 sequences
            for (valid_data) |byte| {
                switch (byte) {
                    '"' => response_buf.appendSlice(session.allocator, "\\\"") catch return .disarm,
                    '\\' => response_buf.appendSlice(session.allocator, "\\\\") catch return .disarm,
                    '\n' => response_buf.appendSlice(session.allocator, "\\n") catch return .disarm,
                    '\r' => response_buf.appendSlice(session.allocator, "\\r") catch return .disarm,
                    '\t' => response_buf.appendSlice(session.allocator, "\\t") catch return .disarm,
                    0x08 => response_buf.appendSlice(session.allocator, "\\b") catch return .disarm,
                    0x0C => response_buf.appendSlice(session.allocator, "\\f") catch return .disarm,
                    0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => {
                        const escaped = std.fmt.allocPrint(session.allocator, "\\u{x:0>4}", .{byte}) catch return .disarm;
                        defer session.allocator.free(escaped);
                        response_buf.appendSlice(session.allocator, escaped) catch return .disarm;
                    },
                    else => response_buf.append(session.allocator, byte) catch return .disarm,
                }
            }

            response_buf.appendSlice(session.allocator, "\"}}\n") catch return .disarm;
            const response = response_buf.items;

            // Send to all attached clients using async write
            var it = session.attached_clients.keyIterator();
            while (it.next()) |client_fd| {
                const attached_client = ctx.clients.get(client_fd.*) orelse continue;
                const owned_response = session.allocator.dupe(u8, response) catch continue;

                const write_ctx = session.allocator.create(PtyWriteContext) catch {
                    session.allocator.free(owned_response);
                    continue;
                };
                write_ctx.* = .{
                    .allocator = session.allocator,
                    .message = owned_response,
                };

                const write_completion = session.allocator.create(xev.Completion) catch {
                    session.allocator.free(owned_response);
                    session.allocator.destroy(write_ctx);
                    continue;
                };

                attached_client.stream.write(
                    loop,
                    write_completion,
                    .{ .slice = owned_response },
                    PtyWriteContext,
                    write_ctx,
                    ptyWriteCallback,
                );
            }
        }

        // Re-arm to continue reading
        stream.read(
            loop,
            completion,
            .{ .slice = &session.pty_read_buffer },
            PtyReadContext,
            pty_ctx,
            readPtyCallback,
        );
        return .disarm;
    } else |err| {
        // WouldBlock is expected for non-blocking I/O
        if (err == error.WouldBlock) {
            stream.read(
                loop,
                completion,
                .{ .slice = &session.pty_read_buffer },
                PtyReadContext,
                pty_ctx,
                readPtyCallback,
            );
            return .disarm;
        }

        // Fatal error - notify clients and clean up
        std.debug.print("PTY read error: {s}\n", .{@errorName(err)});
        const error_msg = std.fmt.allocPrint(
            ctx.allocator,
            "PTY read error: {s}",
            .{@errorName(err)},
        ) catch "PTY read error";
        defer if (!std.mem.eql(u8, error_msg, "PTY read error")) ctx.allocator.free(error_msg);

        notifyAttachedClientsAndCleanup(session, ctx, error_msg);
        ctx.allocator.destroy(pty_ctx);
        ctx.allocator.destroy(completion);
        return .disarm;
    }
    unreachable;
}

fn ptyWriteCallback(
    write_ctx_opt: ?*PtyWriteContext,
    _: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    write_result: xev.WriteError!usize,
) xev.CallbackAction {
    const write_ctx = write_ctx_opt.?;
    const allocator = write_ctx.allocator;

    if (write_result) |_| {
        // Successfully sent PTY output to client
    } else |_| {
        // Silently ignore write errors to prevent log spam
    }

    allocator.free(write_ctx.message);
    allocator.destroy(write_ctx);
    allocator.destroy(completion);
    return .disarm;
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

    // Initialize terminal emulator for session restore
    var vt = try ghostty.Terminal.init(allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10000,
    });
    errdefer vt.deinit(allocator);

    const session = try allocator.create(Session);
    session.* = .{
        .name = try allocator.dupe(u8, session_name),
        .pty_master_fd = @intCast(master_fd),
        .buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
        .child_pid = pid,
        .allocator = allocator,
        .pty_read_buffer = undefined,
        .created_at = std.time.timestamp(),
        .vt = vt,
        .vt_handler = VTHandler{ .terminal = &session.vt },
        .vt_stream = undefined,
        .attached_clients = std.AutoHashMap(std.posix.fd_t, void).init(allocator),
        .utf8_partial = undefined,
        .utf8_partial_len = 0,
    };

    // Initialize the stream after session is created since handler needs terminal pointer
    session.vt_stream = ghostty.Stream(*VTHandler).init(&session.vt_handler);
    session.vt_stream.parser.osc_parser.alloc = allocator;

    return session;
}

fn closeClient(client: *Client, completion: *xev.Completion) xev.CallbackAction {
    std.debug.print("Closing client fd={d}\n", .{client.fd});

    // Remove client from attached session if any
    if (client.attached_session) |session_name| {
        if (client.server_ctx.sessions.get(session_name)) |session| {
            _ = session.attached_clients.remove(client.fd);
            std.debug.print("Removed client fd={d} from session {s} attached_clients\n", .{ client.fd, session_name });
        }
    }

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
    client.message_buffer.deinit(client.allocator);
    client.allocator.destroy(completion);
    client.allocator.destroy(client);
    return .disarm;
}
