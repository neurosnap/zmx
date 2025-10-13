const std = @import("std");
const posix = std.posix;
const xevg = @import("xev");
const xev = xevg.Dynamic;
const clap = @import("clap");
const config_mod = @import("config.zig");
const protocol = @import("protocol.zig");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

// Main context for the attach client that manages connection to daemon and terminal I/O.
// Handles async streams for daemon socket, stdin, and stdout using libxev's event loop.
// Tracks detach key sequence state and buffers partial binary frames from PTY output.
const Context = struct {
    stream: xev.Stream,
    stdin_stream: xev.Stream,
    stdout_stream: xev.Stream,
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    session_name: []const u8,
    prefix_pressed: bool = false,
    should_exit: bool = false,
    stdin_completion: ?*xev.Completion = null,
    stdin_ctx: ?*StdinContext = null,
    read_completion: ?*xev.Completion = null,
    read_ctx: ?*ReadContext = null,
    config: config_mod.Config,
    frame_buffer: std.ArrayList(u8),
    frame_expecting_bytes: usize = 0,
};

const params = clap.parseParamsComptime(
    \\-s, --socket-path <str>  Path to the Unix socket file
    \\<str>
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

    const session_name = res.positionals[0] orelse {
        std.debug.print("Usage: zmx attach <session-name>\n", .{});
        return error.MissingSessionName;
    };

    var thread_pool = xevg.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    var unix_addr = try std.net.Address.initUnix(socket_path);
    // AF.UNIX: Unix domain socket for local IPC with daemon process
    // SOCK.STREAM: Reliable, connection-oriented communication for protocol messages
    // SOCK.NONBLOCK: Prevents blocking to work with libxev's async event loop
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    // Save original terminal settings first (before connecting)
    var orig_termios: c.termios = undefined;
    _ = c.tcgetattr(posix.STDIN_FILENO, &orig_termios);

    posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen()) catch |err| {
        if (err == error.ConnectionRefused) {
            std.debug.print("Error: Unable to connect to zmx daemon at {s}\nPlease start the daemon first with: zmx daemon\n", .{socket_path});
            return err;
        }
        return err;
    };

    // Set raw mode after successful connection
    defer _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &orig_termios);

    var raw_termios = orig_termios;
    c.cfmakeraw(&raw_termios);
    _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &raw_termios);

    const ctx = try allocator.create(Context);
    ctx.* = .{
        .stream = xev.Stream.initFd(socket_fd),
        .stdin_stream = xev.Stream.initFd(posix.STDIN_FILENO),
        .stdout_stream = xev.Stream.initFd(posix.STDOUT_FILENO),
        .allocator = allocator,
        .loop = &loop,
        .session_name = session_name,
        .config = config,
        .frame_buffer = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable,
    };

    // Get terminal size
    var ws: c.struct_winsize = undefined;
    const result = c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws);
    const rows: u16 = if (result == 0) ws.ws_row else 24;
    const cols: u16 = if (result == 0) ws.ws_col else 80;

    const request_payload = protocol.AttachSessionRequest{
        .session_name = session_name,
        .rows = rows,
        .cols = cols,
    };
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const msg = protocol.Message(@TypeOf(request_payload)){
        .type = protocol.MessageType.attach_session_request.toString(),
        .payload = request_payload,
    };

    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.write(msg);
    try out.writer.writeByte('\n');

    const request = try allocator.dupe(u8, out.written());
    defer allocator.free(request);

    const write_completion = try allocator.create(xev.Completion);
    ctx.stream.write(&loop, write_completion, .{ .slice = request }, Context, ctx, writeCallback);

    try loop.run(.until_done);
}

fn writeCallback(
    ctx_opt: ?*Context,
    _: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    write_result: xev.WriteError!usize,
) xev.CallbackAction {
    const ctx = ctx_opt.?;
    if (write_result) |_| {
        // Request sent successfully
    } else |err| {
        std.debug.print("write failed: {s}\n", .{@errorName(err)});
        return cleanup(ctx, completion);
    }

    // Now read the response
    const read_ctx = ctx.allocator.create(ReadContext) catch @panic("failed to create read context");
    read_ctx.* = .{
        .ctx = ctx,
        .buffer = undefined,
    };

    const read_completion = ctx.allocator.create(xev.Completion) catch @panic("failed to create completion");

    // Track read completion and context for cleanup
    ctx.read_completion = read_completion;
    ctx.read_ctx = read_ctx;

    ctx.stream.read(ctx.loop, read_completion, .{ .slice = &read_ctx.buffer }, ReadContext, read_ctx, readCallback);

    ctx.allocator.destroy(completion);
    return .disarm;
}

// Context for async socket read operations from daemon.
// Uses large buffer (128KB) to handle initial session scrollback and binary PTY frames.
const ReadContext = struct {
    ctx: *Context,
    buffer: [128 * 1024]u8, // 128KB to handle large scrollback messages
};

fn readCallback(
    read_ctx_opt: ?*ReadContext,
    _: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    read_buffer: xev.ReadBuffer,
    read_result: xev.ReadError!usize,
) xev.CallbackAction {
    const read_ctx = read_ctx_opt.?;
    const ctx = read_ctx.ctx;

    if (read_result) |len| {
        if (len == 0) {
            std.debug.print("Server closed connection\n", .{});
            return cleanup(ctx, completion);
        }

        const data = read_buffer.slice[0..len];

        // Check if this is a binary frame (starts with FrameHeader)
        if (data.len >= @sizeOf(protocol.FrameHeader)) {
            const potential_header = data[0..@sizeOf(protocol.FrameHeader)];
            const header: *const protocol.FrameHeader = @ptrCast(@alignCast(potential_header));

            if (header.frame_type == @intFromEnum(protocol.FrameType.pty_binary)) {
                // This is a binary PTY frame
                const expected_total = @sizeOf(protocol.FrameHeader) + header.length;
                if (data.len >= expected_total) {
                    // We have the complete frame
                    const payload = data[@sizeOf(protocol.FrameHeader)..expected_total];
                    writeToStdout(ctx, payload);
                    return .rearm;
                } else {
                    // Partial frame, buffer it
                    ctx.frame_buffer.appendSlice(ctx.allocator, data) catch {};
                    ctx.frame_expecting_bytes = expected_total - data.len;
                    return .rearm;
                }
            }
        }

        // If we're expecting more frame bytes, accumulate them
        if (ctx.frame_expecting_bytes > 0) {
            ctx.frame_buffer.appendSlice(ctx.allocator, data) catch {};
            if (ctx.frame_buffer.items.len >= @sizeOf(protocol.FrameHeader)) {
                const header: *const protocol.FrameHeader = @ptrCast(@alignCast(ctx.frame_buffer.items[0..@sizeOf(protocol.FrameHeader)]));
                const expected_total = @sizeOf(protocol.FrameHeader) + header.length;

                if (ctx.frame_buffer.items.len >= expected_total) {
                    // Complete frame received
                    const payload = ctx.frame_buffer.items[@sizeOf(protocol.FrameHeader)..expected_total];
                    writeToStdout(ctx, payload);
                    ctx.frame_buffer.clearRetainingCapacity();
                    ctx.frame_expecting_bytes = 0;
                }
            }
            return .rearm;
        }

        // Otherwise parse as JSON control message
        const newline_idx = std.mem.indexOf(u8, data, "\n") orelse {
            return .rearm;
        };

        const msg_line = data[0..newline_idx];

        const msg_type_parsed = protocol.parseMessageType(ctx.allocator, msg_line) catch |err| {
            std.debug.print("JSON parse error: {s}\n", .{@errorName(err)});
            return .rearm;
        };
        defer msg_type_parsed.deinit();

        const msg_type = protocol.MessageType.fromString(msg_type_parsed.value.type) orelse {
            std.debug.print("Unknown message type: {s}\n", .{msg_type_parsed.value.type});
            return .rearm;
        };

        switch (msg_type) {
            .attach_session_response => {
                const parsed = protocol.parseMessage(protocol.AttachSessionResponse, ctx.allocator, msg_line) catch |err| {
                    std.debug.print("Failed to parse attach response: {s}\n", .{@errorName(err)});
                    return .rearm;
                };
                defer parsed.deinit();

                if (std.mem.eql(u8, parsed.value.payload.status, "ok")) {
                    const client_fd = parsed.value.payload.client_fd orelse {
                        std.debug.print("Missing client_fd in response\n", .{});
                        return .rearm;
                    };

                    // Write client_fd to a file so shell commands can read it
                    const home_dir = posix.getenv("HOME") orelse "/tmp";
                    const client_fd_path = std.fmt.allocPrint(
                        ctx.allocator,
                        "{s}/.zmx_client_fd_{s}",
                        .{ home_dir, ctx.session_name },
                    ) catch |err| {
                        std.debug.print("Failed to create client_fd path: {s}\n", .{@errorName(err)});
                        return .rearm;
                    };
                    defer ctx.allocator.free(client_fd_path);

                    const file = std.fs.cwd().createFile(client_fd_path, .{ .truncate = true }) catch |err| {
                        std.debug.print("Failed to create client_fd file: {s}\n", .{@errorName(err)});
                        return .rearm;
                    };
                    defer file.close();

                    const fd_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{client_fd}) catch return .rearm;
                    defer ctx.allocator.free(fd_str);

                    file.writeAll(fd_str) catch |err| {
                        std.debug.print("Failed to write client_fd: {s}\n", .{@errorName(err)});
                        return .rearm;
                    };

                    startStdinReading(ctx);
                } else {
                    _ = posix.write(posix.STDERR_FILENO, "Attach failed: ") catch {};
                    _ = posix.write(posix.STDERR_FILENO, parsed.value.payload.status) catch {};
                    _ = posix.write(posix.STDERR_FILENO, "\n") catch {};
                }
            },
            .detach_session_response => {
                const parsed = protocol.parseMessage(protocol.DetachSessionResponse, ctx.allocator, msg_line) catch |err| {
                    std.debug.print("Failed to parse detach response: {s}\n", .{@errorName(err)});
                    return .rearm;
                };
                defer parsed.deinit();

                if (std.mem.eql(u8, parsed.value.payload.status, "ok")) {
                    cleanupClientFdFile(ctx);
                    _ = posix.write(posix.STDERR_FILENO, "\r\nDetached from session\r\n") catch {};
                    return cleanup(ctx, completion);
                }
            },
            .detach_notification => {
                cleanupClientFdFile(ctx);
                _ = posix.write(posix.STDERR_FILENO, "\r\nDetached from session (external request)\r\n") catch {};
                return cleanup(ctx, completion);
            },
            .kill_notification => {
                cleanupClientFdFile(ctx);
                _ = posix.write(posix.STDERR_FILENO, "\r\nSession killed\r\n") catch {};
                return cleanup(ctx, completion);
            },
            .pty_out => {
                const parsed = protocol.parseMessage(protocol.PtyOutput, ctx.allocator, msg_line) catch |err| {
                    std.debug.print("Failed to parse pty_out: {s}\n", .{@errorName(err)});
                    return .rearm;
                };
                defer parsed.deinit();

                writeToStdout(ctx, parsed.value.payload.text);
            },
            else => {
                std.debug.print("Unexpected message type in attach client: {s}\n", .{msg_type.toString()});
            },
        }

        return .rearm;
    } else |err| {
        std.debug.print("read failed: {s}\n", .{@errorName(err)});
    }

    ctx.allocator.destroy(read_ctx);
    ctx.read_ctx = null;
    return cleanup(ctx, completion);
}

fn startStdinReading(ctx: *Context) void {
    const stdin_ctx = ctx.allocator.create(StdinContext) catch @panic("failed to create stdin context");
    stdin_ctx.* = .{
        .ctx = ctx,
        .buffer = undefined,
    };

    const stdin_completion = ctx.allocator.create(xev.Completion) catch @panic("failed to create completion");

    // Track stdin completion and context for cleanup
    ctx.stdin_completion = stdin_completion;
    ctx.stdin_ctx = stdin_ctx;

    ctx.stdin_stream.read(ctx.loop, stdin_completion, .{ .slice = &stdin_ctx.buffer }, StdinContext, stdin_ctx, stdinReadCallback);
}

// Context for async stdin read operations.
// Captures user terminal input to forward to PTY via daemon.
const StdinContext = struct {
    ctx: *Context,
    buffer: [4096]u8,
};

fn cleanupClientFdFile(ctx: *Context) void {
    const home_dir = posix.getenv("HOME") orelse "/tmp";
    const client_fd_path = std.fmt.allocPrint(
        ctx.allocator,
        "{s}/.zmx_client_fd_{s}",
        .{ home_dir, ctx.session_name },
    ) catch return;
    defer ctx.allocator.free(client_fd_path);

    std.fs.cwd().deleteFile(client_fd_path) catch {};
}

fn sendDetachRequest(ctx: *Context) void {
    const request_payload = protocol.DetachSessionRequest{ .session_name = ctx.session_name };
    var out: std.io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();

    const msg = protocol.Message(@TypeOf(request_payload)){
        .type = protocol.MessageType.detach_session_request.toString(),
        .payload = request_payload,
    };

    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    stringify.write(msg) catch return;
    out.writer.writeByte('\n') catch return;

    const request = ctx.allocator.dupe(u8, out.written()) catch return;

    const write_ctx = ctx.allocator.create(StdinWriteContext) catch return;
    write_ctx.* = .{
        .allocator = ctx.allocator,
        .message = request,
    };

    const write_completion = ctx.allocator.create(xev.Completion) catch return;
    ctx.stream.write(ctx.loop, write_completion, .{ .slice = write_ctx.message }, StdinWriteContext, write_ctx, stdinWriteCallback);
}

fn sendPtyInput(ctx: *Context, data: []const u8) void {
    const request_payload = protocol.PtyInput{ .text = data };
    var out: std.io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();

    const msg = protocol.Message(@TypeOf(request_payload)){
        .type = protocol.MessageType.pty_in.toString(),
        .payload = request_payload,
    };

    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    stringify.write(msg) catch return;
    out.writer.writeByte('\n') catch return;

    const owned_message = ctx.allocator.dupe(u8, out.written()) catch return;

    const write_ctx = ctx.allocator.create(StdinWriteContext) catch return;
    write_ctx.* = .{
        .allocator = ctx.allocator,
        .message = owned_message,
    };

    const write_completion = ctx.allocator.create(xev.Completion) catch return;
    ctx.stream.write(ctx.loop, write_completion, .{ .slice = owned_message }, StdinWriteContext, write_ctx, stdinWriteCallback);
}

// Context for async write operations to daemon socket.
// Owns message buffer that gets freed after write completes.
const StdinWriteContext = struct {
    allocator: std.mem.Allocator,
    message: []u8,
};

// Context for async write operations to stdout.
// Owns PTY output data buffer that gets freed after write completes.
const StdoutWriteContext = struct {
    allocator: std.mem.Allocator,
    data: []u8,
};

fn writeToStdout(ctx: *Context, data: []const u8) void {
    const owned_data = ctx.allocator.dupe(u8, data) catch return;

    const write_ctx = ctx.allocator.create(StdoutWriteContext) catch {
        ctx.allocator.free(owned_data);
        return;
    };
    write_ctx.* = .{
        .allocator = ctx.allocator,
        .data = owned_data,
    };

    const write_completion = ctx.allocator.create(xev.Completion) catch {
        ctx.allocator.free(owned_data);
        ctx.allocator.destroy(write_ctx);
        return;
    };

    ctx.stdout_stream.write(ctx.loop, write_completion, .{ .slice = owned_data }, StdoutWriteContext, write_ctx, stdoutWriteCallback);
}

fn stdoutWriteCallback(
    write_ctx_opt: ?*StdoutWriteContext,
    _: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    write_result: xev.WriteError!usize,
) xev.CallbackAction {
    const write_ctx = write_ctx_opt.?;
    const allocator = write_ctx.allocator;

    if (write_result) |_| {
        // Successfully wrote to stdout
    } else |_| {
        // Silently ignore stdout write errors
    }

    allocator.free(write_ctx.data);
    allocator.destroy(write_ctx);
    allocator.destroy(completion);
    return .disarm;
}

fn stdinReadCallback(
    stdin_ctx_opt: ?*StdinContext,
    _: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    read_buffer: xev.ReadBuffer,
    read_result: xev.ReadError!usize,
) xev.CallbackAction {
    const stdin_ctx = stdin_ctx_opt.?;
    const ctx = stdin_ctx.ctx;

    if (read_result) |len| {
        if (len == 0) {
            std.debug.print("stdin closed\n", .{});
            ctx.stdin_completion = null;
            ctx.stdin_ctx = null;
            ctx.allocator.destroy(stdin_ctx);
            ctx.allocator.destroy(completion);
            return .disarm;
        }

        const data = read_buffer.slice[0..len];

        // Detect prefix for detach command
        if (len == 1 and data[0] == ctx.config.detach_prefix) {
            ctx.prefix_pressed = true;
            return .rearm;
        }

        // If prefix was pressed and now we got the detach key, detach
        if (ctx.prefix_pressed and len == 1 and data[0] == ctx.config.detach_key) {
            ctx.prefix_pressed = false;
            sendDetachRequest(ctx);
            return .rearm;
        }

        // If prefix was pressed but we got something else, send the prefix and the new data
        if (ctx.prefix_pressed) {
            ctx.prefix_pressed = false;
            // Send the prefix that was buffered
            const prefix_data = [_]u8{ctx.config.detach_prefix};
            sendPtyInput(ctx, &prefix_data);
            // Fall through to send the current data
        }

        sendPtyInput(ctx, data);

        return .rearm;
    } else |err| {
        std.debug.print("stdin read failed: {s}\n", .{@errorName(err)});
        ctx.stdin_completion = null;
        ctx.stdin_ctx = null;
        ctx.allocator.destroy(stdin_ctx);
        ctx.allocator.destroy(completion);
        return .disarm;
    }
}

fn stdinWriteCallback(
    write_ctx_opt: ?*StdinWriteContext,
    _: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    write_result: xev.WriteError!usize,
) xev.CallbackAction {
    const write_ctx = write_ctx_opt.?;

    if (write_result) |_| {
        // Successfully sent stdin to daemon
    } else |err| {
        std.debug.print("Failed to send stdin to daemon: {s}\n", .{@errorName(err)});
    }

    // Clean up - save allocator before destroying write_ctx
    const allocator = write_ctx.allocator;
    allocator.free(write_ctx.message);
    allocator.destroy(write_ctx);
    allocator.destroy(completion);
    return .disarm;
}

fn cleanup(ctx: *Context, completion: *xev.Completion) xev.CallbackAction {
    // Track whether we've freed the passed completion
    var completion_freed = false;

    // Clean up stdin completion and context if they exist
    if (ctx.stdin_completion) |stdin_completion| {
        if (stdin_completion == completion) {
            completion_freed = true;
        }
        ctx.allocator.destroy(stdin_completion);
        ctx.stdin_completion = null;
    }
    if (ctx.stdin_ctx) |stdin_ctx| {
        ctx.allocator.destroy(stdin_ctx);
        ctx.stdin_ctx = null;
    }

    // Clean up read completion and context if they exist
    if (ctx.read_completion) |read_completion| {
        if (read_completion == completion) {
            completion_freed = true;
        }
        ctx.allocator.destroy(read_completion);
        ctx.read_completion = null;
    }
    if (ctx.read_ctx) |read_ctx| {
        ctx.allocator.destroy(read_ctx);
        ctx.read_ctx = null;
    }

    const close_completion = ctx.allocator.create(xev.Completion) catch @panic("failed to create completion");
    ctx.stream.close(ctx.loop, close_completion, Context, ctx, closeCallback);

    // Only destroy completion if we haven't already freed it above
    if (!completion_freed) {
        ctx.allocator.destroy(completion);
    }

    return .disarm;
}

fn closeCallback(
    ctx_opt: ?*Context,
    loop: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    close_result: xev.CloseError!void,
) xev.CallbackAction {
    const ctx = ctx_opt.?;
    if (close_result) |_| {
        std.debug.print("Connection closed\n", .{});
    } else |err| {
        std.debug.print("close failed: {s}\n", .{@errorName(err)});
    }
    const allocator = ctx.allocator;
    ctx.frame_buffer.deinit(allocator);
    allocator.destroy(completion);
    allocator.destroy(ctx);
    loop.stop();
    return .disarm;
}
