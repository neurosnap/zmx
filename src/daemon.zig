const std = @import("std");
const posix = std.posix;
const xevg = @import("xev");
const xev = xevg.Dynamic;
const clap = @import("clap");
const config_mod = @import("config.zig");
const protocol = @import("protocol.zig");
const builtin = @import("builtin");

const ghostty = @import("ghostty-vt");
const sgr = @import("sgr.zig");
const terminal_snapshot = @import("terminal_snapshot.zig");

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
    pty_master_fd: std.posix.fd_t,

    pub fn print(self: *VTHandler, cp: u21) !void {
        try self.terminal.print(cp);
    }

    pub fn setMode(self: *VTHandler, mode: ghostty.Mode, enabled: bool) !void {
        self.terminal.modes.set(mode, enabled);
        std.debug.print("Mode changed: {s} = {}\n", .{ @tagName(mode), enabled });
    }

    // SGR attributes (colors, bold, italic, etc.)
    pub fn setAttribute(self: *VTHandler, attr: ghostty.Attribute) !void {
        try self.terminal.setAttribute(attr);
    }

    // Cursor positioning
    pub fn setCursorPos(self: *VTHandler, row: usize, col: usize) !void {
        self.terminal.setCursorPos(row, col);
    }

    pub fn setCursorRow(self: *VTHandler, row: usize) !void {
        self.terminal.setCursorPos(row, self.terminal.screen.cursor.x);
    }

    pub fn setCursorCol(self: *VTHandler, col: usize) !void {
        self.terminal.setCursorPos(self.terminal.screen.cursor.y, col);
    }

    // Screen/line erasing
    pub fn eraseDisplay(self: *VTHandler, mode: ghostty.EraseDisplay, protected: bool) !void {
        self.terminal.eraseDisplay(mode, protected);
    }

    pub fn eraseLine(self: *VTHandler, mode: ghostty.EraseLine, protected: bool) !void {
        self.terminal.eraseLine(mode, protected);
    }

    // Scroll regions
    pub fn setTopAndBottomMargin(self: *VTHandler, top: usize, bottom: usize) !void {
        self.terminal.setTopAndBottomMargin(top, bottom);
    }

    // Cursor save/restore
    pub fn saveCursor(self: *VTHandler) !void {
        self.terminal.saveCursor();
    }

    pub fn restoreCursor(self: *VTHandler) !void {
        try self.terminal.restoreCursor();
    }

    // Tab stops
    pub fn tabSet(self: *VTHandler) !void {
        self.terminal.tabSet();
    }

    pub fn tabClear(self: *VTHandler, cmd: ghostty.TabClear) !void {
        self.terminal.tabClear(cmd);
    }

    pub fn tabReset(self: *VTHandler) !void {
        self.terminal.tabReset();
    }

    // Cursor movement (relative)
    pub fn cursorUp(self: *VTHandler, count: usize) !void {
        self.terminal.cursorUp(count);
    }

    pub fn cursorDown(self: *VTHandler, count: usize) !void {
        self.terminal.cursorDown(count);
    }

    pub fn cursorForward(self: *VTHandler, count: usize) !void {
        self.terminal.cursorRight(count);
    }

    pub fn cursorBack(self: *VTHandler, count: usize) !void {
        self.terminal.cursorLeft(count);
    }

    pub fn setCursorColRelative(self: *VTHandler, count: usize) !void {
        const new_col = self.terminal.screen.cursor.x + count;
        self.terminal.setCursorPos(self.terminal.screen.cursor.y, new_col);
    }

    pub fn setCursorRowRelative(self: *VTHandler, count: usize) !void {
        const new_row = self.terminal.screen.cursor.y + count;
        self.terminal.setCursorPos(new_row, self.terminal.screen.cursor.x);
    }

    // Special movement (ESC sequences)
    pub fn index(self: *VTHandler) !void {
        try self.terminal.index();
    }

    pub fn reverseIndex(self: *VTHandler) !void {
        self.terminal.reverseIndex();
    }

    pub fn nextLine(self: *VTHandler) !void {
        try self.terminal.linefeed();
        self.terminal.carriageReturn();
    }

    pub fn prevLine(self: *VTHandler) !void {
        self.terminal.reverseIndex();
        self.terminal.carriageReturn();
    }

    // Line/char editing
    pub fn insertLines(self: *VTHandler, count: usize) !void {
        self.terminal.insertLines(count);
    }

    pub fn deleteLines(self: *VTHandler, count: usize) !void {
        self.terminal.deleteLines(count);
    }

    pub fn deleteChars(self: *VTHandler, count: usize) !void {
        self.terminal.deleteChars(count);
    }

    pub fn eraseChars(self: *VTHandler, count: usize) !void {
        self.terminal.eraseChars(count);
    }

    pub fn scrollUp(self: *VTHandler, count: usize) !void {
        self.terminal.scrollUp(count);
    }

    pub fn scrollDown(self: *VTHandler, count: usize) !void {
        self.terminal.scrollDown(count);
    }

    // Basic control characters
    pub fn carriageReturn(self: *VTHandler) !void {
        self.terminal.carriageReturn();
    }

    pub fn linefeed(self: *VTHandler) !void {
        try self.terminal.linefeed();
    }

    pub fn backspace(self: *VTHandler) !void {
        self.terminal.backspace();
    }

    pub fn horizontalTab(self: *VTHandler, count: usize) !void {
        _ = count; // stream always passes 1
        try self.terminal.horizontalTab();
    }

    pub fn horizontalTabBack(self: *VTHandler, count: usize) !void {
        _ = count; // stream always passes 1
        try self.terminal.horizontalTabBack();
    }

    pub fn bell(self: *VTHandler) !void {
        _ = self;
        // Ignore bell in daemon context - no UI to notify
    }

    pub fn deviceAttributes(
        self: *VTHandler,
        req: ghostty.DeviceAttributeReq,
        da_params: []const u16,
    ) !void {
        _ = da_params;

        const response = getDeviceAttributeResponse(req) orelse return;

        _ = posix.write(self.pty_master_fd, response) catch |err| {
            std.debug.print("Error writing DA response to PTY: {s}\n", .{@errorName(err)});
        };

        std.debug.print("Responded to DA query ({s}) with {s}\n", .{ @tagName(req), response });
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
    child_pid: std.posix.pid_t,
    allocator: std.mem.Allocator,
    pty_read_buffer: [128 * 1024]u8, // 128KB for high-throughput PTY output
    created_at: i64,

    // Terminal emulator state for session restore
    vt: ghostty.Terminal,
    vt_stream: ghostty.Stream(*VTHandler),
    vt_handler: VTHandler,
    attached_clients: std.AutoHashMap(std.posix.fd_t, void),
    pty_reading: bool = false, // Track if PTY reads are active

    fn deinit(self: *Session) void {
        self.allocator.free(self.name);
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
    read_buffer: [128 * 1024]u8, // 128KB for high-throughput socket reads
    allocator: std.mem.Allocator,
    attached_session: ?[]const u8,
    server_ctx: *ServerContext,
    message_buffer: std.ArrayList(u8),
    /// Gate for preventing live PTY output during snapshot send
    /// When true, this client will not receive live PTY frames
    muted: bool = false,
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

        // Check for binary frames first
        while (client.message_buffer.items.len >= @sizeOf(protocol.FrameHeader)) {
            const header: *const protocol.FrameHeader = @ptrCast(@alignCast(client.message_buffer.items.ptr));

            if (header.frame_type == @intFromEnum(protocol.FrameType.pty_binary)) {
                const expected_total = @sizeOf(protocol.FrameHeader) + header.length;
                if (client.message_buffer.items.len >= expected_total) {
                    const payload = client.message_buffer.items[@sizeOf(protocol.FrameHeader)..expected_total];
                    handleBinaryFrame(client, payload) catch |err| {
                        std.debug.print("handleBinaryFrame failed: {s}\n", .{@errorName(err)});
                        return closeClient(client, completion);
                    };

                    // Remove processed frame from buffer
                    const remaining = client.message_buffer.items[expected_total..];
                    const remaining_copy = client.allocator.dupe(u8, remaining) catch {
                        return closeClient(client, completion);
                    };
                    client.message_buffer.clearRetainingCapacity();
                    client.message_buffer.appendSlice(client.allocator, remaining_copy) catch {
                        client.allocator.free(remaining_copy);
                        return closeClient(client, completion);
                    };
                    client.allocator.free(remaining_copy);
                } else {
                    // Incomplete frame, wait for more data
                    break;
                }
            } else {
                // Not a binary frame, try JSON
                break;
            }
        }

        // Process complete JSON messages (delimited by newline)
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

fn handleBinaryFrame(client: *Client, payload: []const u8) !void {
    try handlePtyInput(client, payload);
}

fn handleMessage(client: *Client, data: []const u8) !void {
    std.debug.print("Received message from client fd={d}: {s}\n", .{ client.fd, data });

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
            std.debug.print("Handling attach request for session: {s} ({}x{}) cwd={s}\n", .{ parsed.value.payload.session_name, parsed.value.payload.cols, parsed.value.payload.rows, parsed.value.payload.cwd });
            try handleAttachSession(client.server_ctx, client, parsed.value.payload.session_name, parsed.value.payload.rows, parsed.value.payload.cols, parsed.value.payload.cwd);
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

    std.debug.print("Sending list response to client fd={d}: {s}\n", .{ client.fd, response.items });

    const written = posix.write(client.fd, response.items) catch |err| {
        std.debug.print("Error writing to fd={d}: {s}\n", .{ client.fd, @errorName(err) });
        return err;
    };
    _ = written;
}

fn handleAttachSession(ctx: *ServerContext, client: *Client, session_name: []const u8, rows: u16, cols: u16, cwd: []const u8) !void {
    // Check if session already exists
    const is_reattach = ctx.sessions.contains(session_name);
    const session = if (is_reattach) blk: {
        std.debug.print("Attaching to existing session: {s}\n", .{session_name});
        break :blk ctx.sessions.get(session_name).?;
    } else blk: {
        // Create new session with forkpty
        std.debug.print("Creating new session: {s}\n", .{session_name});
        const new_session = try createSession(ctx.allocator, session_name, cwd);
        try ctx.sessions.put(new_session.name, new_session);
        break :blk new_session;
    };

    // Mark client as attached
    client.attached_session = session.name;

    // Mute client before adding to attached_clients to prevent PTY interleaving during snapshot
    if (is_reattach) {
        client.muted = true;
    }

    try session.attached_clients.put(client.fd, {});

    // Start reading from PTY if not already started (first client)
    const is_first_client = session.attached_clients.count() == 1;
    std.debug.print("is_reattach={}, is_first_client={}, attached_clients.count={}\n", .{ is_reattach, is_first_client, session.attached_clients.count() });

    // For reattaching clients, resize VT BEFORE snapshot so snapshot matches client size
    // But defer TIOCSWINSZ until after snapshot to prevent SIGWINCH during send
    if (is_reattach) {
        if (rows > 0 and cols > 0) {
            // Only resize VT if geometry changed
            if (session.vt.cols != cols or session.vt.rows != rows) {
                try session.vt.resize(session.allocator, cols, rows);
                std.debug.print("Resized VT to {d}x{d} before snapshot\n", .{ cols, rows });
            }
        }

        // Render snapshot at correct client size
        const buffer_slice = try terminal_snapshot.render(&session.vt, client.allocator);
        defer client.allocator.free(buffer_slice);

        try protocol.writeBinaryFrame(client.fd, .pty_binary, buffer_slice);
        std.debug.print("Sent scrollback buffer to client fd={d} ({d} bytes)\n", .{ client.fd, buffer_slice.len });

        // Unmute client before TIOCSWINSZ so client can receive the redraw
        client.muted = false;

        // Now send TIOCSWINSZ to trigger app (vim) redraw - client will receive it
        try applyWinsize(session, rows, cols);
    } else if (!is_reattach and rows > 0 and cols > 0) {
        // New session: just resize normally
        try session.vt.resize(session.allocator, cols, rows);
        try applyWinsize(session, rows, cols);
    }

    // Only start PTY reading if not already started
    if (!session.pty_reading) {
        session.pty_reading = true;
        std.debug.print("Starting PTY reads for session {s}\n", .{session.name});
        // Start PTY reads AFTER snapshot is sent (readFromPty sends attach response)
        try readFromPty(ctx, client, session);

        // For first attach to new session, clear the client's terminal
        if (!is_reattach) {
            try protocol.writeBinaryFrame(client.fd, .pty_binary, "\x1b[2J\x1b[H");
        }
    } else {
        // PTY already reading - just send attach response
        std.debug.print("PTY already reading for session {s}, sending attach response to client fd={d}\n", .{ session.name, client.fd });
        const response = protocol.AttachSessionResponse{
            .status = "ok",
            .client_fd = client.fd,
        };
        std.debug.print("Response payload: status={s}, client_fd={?d}\n", .{ response.status, response.client_fd });
        try protocol.writeJson(ctx.allocator, client.fd, .attach_session_response, response);
        std.debug.print("Attach response sent successfully\n", .{});
    }
}

/// Returns the device attribute response zmx should send (matching tmux/screen)
/// Returns null for tertiary DA (ignored)
fn getDeviceAttributeResponse(req: ghostty.DeviceAttributeReq) ?[]const u8 {
    return switch (req) {
        .primary => "\x1b[?1;2c", // VT100 with AVO (matches screen/tmux)
        .secondary => "\x1b[>0;0;0c", // Conservative secondary DA
        .tertiary => null, // Ignore tertiary DA
    };
}

/// Filter out terminal response sequences that the client's terminal sends
/// These should not be written to the PTY since the daemon handles queries itself
///
/// Architecture: When apps send queries (e.g., ESC[c), the client's terminal
/// auto-responds. We must drop those responses because:
/// 1. VTHandler already responds with correct zmx terminal capabilities
/// 2. Client responses describe the client's terminal, not zmx's virtual terminal
/// 3. Without filtering, responses get echoed by PTY and appear as literal text
///
/// This matches tmux/screen behavior: intercept queries, respond ourselves, drop client responses
fn filterTerminalResponses(input: []const u8, output_buf: []u8) usize {
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        // Look for ESC sequences
        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '[') {
            // CSI sequence - parse it
            const seq_start = i;
            i += 2; // Skip ESC [

            // Collect parameter bytes (0x30-0x3F)
            const param_start = i;
            while (i < input.len and input[i] >= 0x30 and input[i] <= 0x3F) : (i += 1) {}
            const seq_params = input[param_start..i];

            // Collect intermediate bytes (0x20-0x2F)
            while (i < input.len and input[i] >= 0x20 and input[i] <= 0x2F) : (i += 1) {}

            // Final byte (0x40-0x7E)
            if (i < input.len and input[i] >= 0x40 and input[i] <= 0x7E) {
                const final = input[i];
                const should_drop = blk: {
                    // Device Attributes responses: ESC[?...c, ESC[>...c, ESC[=...c
                    // These match the responses defined in getDeviceAttributeResponse()
                    if (final == 'c' and seq_params.len > 0) {
                        if (seq_params[0] == '?' or seq_params[0] == '>' or seq_params[0] == '=') {
                            std.debug.print("Filtered DA response: ESC[{s}c\n", .{seq_params});
                            break :blk true;
                        }
                    }
                    // Cursor Position Report: ESC[<row>;<col>R
                    if (final == 'R' and seq_params.len > 0) {
                        // Simple heuristic: if params look like digits/semicolon, it's likely CPR
                        var is_cpr = true;
                        for (seq_params) |byte| {
                            if (byte != ';' and (byte < '0' or byte > '9')) {
                                is_cpr = false;
                                break;
                            }
                        }
                        if (is_cpr) {
                            std.debug.print("Filtered CPR: ESC[{s}R\n", .{seq_params});
                            break :blk true;
                        }
                    }
                    // DSR responses: ESC[0n, ESC[3n, ESC[?...n
                    if (final == 'n' and seq_params.len > 0) {
                        if ((seq_params.len == 1 and (seq_params[0] == '0' or seq_params[0] == '3')) or
                            seq_params[0] == '?')
                        {
                            std.debug.print("Filtered DSR response: ESC[{s}n\n", .{seq_params});
                            break :blk true;
                        }
                    }
                    break :blk false;
                };

                if (should_drop) {
                    // Skip this entire sequence, continue to next character
                    i += 1;
                } else {
                    // Copy the entire sequence to output
                    const seq_len = (i + 1) - seq_start;
                    @memcpy(output_buf[out_idx .. out_idx + seq_len], input[seq_start .. i + 1]);
                    out_idx += seq_len;
                    i += 1;
                }
            } else {
                // Incomplete sequence, copy what we have
                const seq_len = i - seq_start;
                @memcpy(output_buf[out_idx .. out_idx + seq_len], input[seq_start..i]);
                out_idx += seq_len;
                // i is already positioned at the next byte
            }
        } else {
            // Not a CSI sequence, copy the byte
            output_buf[out_idx] = input[i];
            out_idx += 1;
            i += 1;
        }
    }

    return out_idx;
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

    // Filter out terminal response sequences before writing to PTY
    var filtered_buf: [128 * 1024]u8 = undefined;
    const filtered_len = filterTerminalResponses(text, &filtered_buf);

    if (filtered_len == 0) {
        return; // All input was filtered, nothing to write
    }

    const filtered_text = filtered_buf[0..filtered_len];
    std.debug.print("Client fd={d}: Writing {d} bytes to PTY fd={d} (filtered from {d} bytes)\n", .{ client.fd, filtered_len, session.pty_master_fd, text.len });

    // Write input to PTY master fd
    const written = posix.write(session.pty_master_fd, filtered_text) catch |err| {
        std.debug.print("Error writing to PTY: {s}\n", .{@errorName(err)});
        return err;
    };
    _ = written;
}

fn applyWinsize(session: *Session, rows: u16, cols: u16) !void {
    if (rows == 0 or cols == 0) return;

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

    try sendInBandSizeReportIfEnabled(session, rows, cols);
}

fn sendInBandSizeReportIfEnabled(session: *Session, rows: u16, cols: u16) !void {
    // Check if in-band size reports mode (2048) is enabled
    if (!session.vt.modes.get(.in_band_size_reports)) {
        return;
    }

    // Format: CSI 48 ; height_chars ; width_chars ; height_pix ; width_pix t
    // We don't track pixel sizes, so report 0 for pixels
    var buf: [128]u8 = undefined;
    const size_report = try std.fmt.bufPrint(&buf, "\x1b[48;{d};{d};0;0t", .{ rows, cols });

    // Write directly to PTY master so app receives it
    _ = try posix.write(session.pty_master_fd, size_report);
    std.debug.print("Sent in-band size report: {s}\n", .{size_report});
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

    // Update PTY window size and send notifications
    try applyWinsize(session, rows, cols);
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

fn notifyAttachedClientsAndCleanup(session: *Session, ctx: *ServerContext, reason: []const u8) void {
    // Copy the session name FIRST before doing anything else, including printing
    // This protects against any potential memory corruption
    const session_name = ctx.allocator.dupe(u8, session.name) catch {
        // Fallback: skip notification and just cleanup
        std.debug.print("Failed to allocate session name copy during cleanup\n", .{});
        posix.close(session.pty_master_fd);
        session.deinit();
        ctx.allocator.destroy(session);
        return;
    };
    defer ctx.allocator.free(session_name);

    std.debug.print("Session '{s}' ending: {s}\n", .{ session_name, reason });

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

    // Check if session still exists (might have been killed by another client)
    const session_exists = blk: {
        var it = ctx.sessions.valueIterator();
        while (it.next()) |s| {
            if (s.* == session) break :blk true;
        }
        break :blk false;
    };

    if (!session_exists) {
        // Session was already cleaned up, just free our context
        ctx.allocator.destroy(pty_ctx);
        ctx.allocator.destroy(completion);
        return .disarm;
    }

    if (read_result) |bytes_read| {
        if (bytes_read == 0) {
            std.debug.print("PTY closed (EOF)\n", .{});
            notifyAttachedClientsAndCleanup(session, ctx, "PTY closed");
            ctx.allocator.destroy(pty_ctx);
            ctx.allocator.destroy(completion);
            return .disarm;
        }

        const data = read_buffer.slice[0..bytes_read];
        std.debug.print("PTY output ({d} bytes)\n", .{bytes_read});

        session.vt_stream.nextSlice(data) catch |err| {
            std.debug.print("VT parse error: {s}\n", .{@errorName(err)});
        };

        // Only proxy to clients if someone is attached
        if (session.attached_clients.count() > 0 and data.len > 0) {
            // Send PTY output as binary frame to avoid JSON escaping issues
            // Frame format: [4-byte length][2-byte type][payload]
            const header = protocol.FrameHeader{
                .length = @intCast(data.len),
                .frame_type = @intFromEnum(protocol.FrameType.pty_binary),
            };

            // Build complete frame with header + payload
            var frame_buf = std.ArrayList(u8).initCapacity(session.allocator, @sizeOf(protocol.FrameHeader) + data.len) catch return .disarm;
            defer frame_buf.deinit(session.allocator);

            const header_bytes = std.mem.asBytes(&header);
            frame_buf.appendSlice(session.allocator, header_bytes) catch return .disarm;
            frame_buf.appendSlice(session.allocator, data) catch return .disarm;

            // Send to all attached clients using async write (skip muted clients)
            var it = session.attached_clients.keyIterator();
            while (it.next()) |client_fd| {
                const attached_client = ctx.clients.get(client_fd.*) orelse continue;
                // Skip muted clients (during snapshot send)
                if (attached_client.muted) continue;
                const owned_frame = session.allocator.dupe(u8, frame_buf.items) catch continue;

                const write_ctx = session.allocator.create(PtyWriteContext) catch {
                    session.allocator.free(owned_frame);
                    continue;
                };
                write_ctx.* = .{
                    .allocator = session.allocator,
                    .message = owned_frame,
                };

                const write_completion = session.allocator.create(xev.Completion) catch {
                    session.allocator.free(owned_frame);
                    session.allocator.destroy(write_ctx);
                    continue;
                };

                attached_client.stream.write(
                    loop,
                    write_completion,
                    .{ .slice = owned_frame },
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

fn createSession(allocator: std.mem.Allocator, session_name: []const u8, cwd: []const u8) !*Session {
    var master_fd: c_int = undefined;

    // Fork and create PTY
    const pid = c.forkpty(&master_fd, null, null, null);
    if (pid < 0) {
        return error.ForkPtyFailed;
    }

    if (pid == 0) {
        // Child process - set environment and execute shell with prompt

        // Change to client's working directory
        std.posix.chdir(cwd) catch {
            std.posix.exit(1);
        };

        // Set ZMX_SESSION to identify the session
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
        .child_pid = pid,
        .allocator = allocator,
        .pty_read_buffer = undefined,
        .created_at = std.time.timestamp(),
        .vt = vt,
        .vt_handler = VTHandler{
            .terminal = &session.vt,
            .pty_master_fd = @intCast(master_fd),
        },
        .vt_stream = undefined,
        .attached_clients = std.AutoHashMap(std.posix.fd_t, void).init(allocator),
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
