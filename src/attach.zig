const std = @import("std");
const posix = std.posix;
const xevg = @import("xev");
const xev = xevg.Dynamic;
const socket_path = "/tmp/zmx.sock";

const c = @cImport({
    @cInclude("termios.h");
});

const Context = struct {
    stream: xev.Stream,
    stdin_stream: xev.Stream,
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    session_name: []const u8,
    prefix_pressed: bool = false,
    should_exit: bool = false,
    stdin_completion: ?*xev.Completion = null,
    stdin_ctx: ?*StdinContext = null,
    read_completion: ?*xev.Completion = null,
    read_ctx: ?*ReadContext = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get session name from command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: zmx attach <session-name>\n", .{});
        std.process.exit(1);
    }

    const session_name = args[2];

    var thread_pool = xevg.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    // Save original terminal settings and set raw mode
    var orig_termios: c.termios = undefined;
    _ = c.tcgetattr(posix.STDIN_FILENO, &orig_termios);
    defer _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &orig_termios);

    var raw_termios = orig_termios;
    c.cfmakeraw(&raw_termios);
    _ = c.tcsetattr(posix.STDIN_FILENO, c.TCSANOW, &raw_termios);

    var unix_addr = try std.net.Address.initUnix(socket_path);
    // AF.UNIX: Unix domain socket for local IPC with daemon process
    // SOCK.STREAM: Reliable, connection-oriented communication for protocol messages
    // SOCK.NONBLOCK: Prevents blocking to work with libxev's async event loop
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    try posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen());
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"attach_session_request\",\"payload\":{{\"session_name\":\"{s}\"}}}}\n",
        .{session_name},
    );
    defer allocator.free(request);

    _ = posix.write(posix.STDERR_FILENO, "Attaching to session: ") catch {};
    _ = posix.write(posix.STDERR_FILENO, session_name) catch {};
    _ = posix.write(posix.STDERR_FILENO, "\n") catch {};

    const ctx = try allocator.create(Context);
    ctx.* = .{
        .stream = xev.Stream.initFd(socket_fd),
        .stdin_stream = xev.Stream.initFd(posix.STDIN_FILENO),
        .allocator = allocator,
        .loop = &loop,
        .session_name = session_name,
    };

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

const ReadContext = struct {
    ctx: *Context,
    buffer: [4096]u8,
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

        // Find newline to get complete message
        const newline_idx = std.mem.indexOf(u8, data, "\n") orelse {
            // std.debug.print("No newline found in {d} bytes, waiting for more data\n", .{len});
            return .rearm;
        };

        const msg_line = data[0..newline_idx];
        // std.debug.print("Parsing message ({d} bytes): {s}\n", .{msg_line.len, msg_line});

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            ctx.allocator,
            msg_line,
            .{},
        ) catch |err| {
            std.debug.print("JSON parse error: {s}\n", .{@errorName(err)});
            return .rearm;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = root.get("type").?.string;
        const payload = root.get("payload").?.object;

        if (std.mem.eql(u8, msg_type, "attach_session_response")) {
            const status = payload.get("status").?.string;
            if (std.mem.eql(u8, status, "ok")) {
                // Get client_fd from response
                const client_fd = payload.get("client_fd").?.integer;

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
                _ = posix.write(posix.STDERR_FILENO, status) catch {};
                _ = posix.write(posix.STDERR_FILENO, "\n") catch {};
            }
        } else if (std.mem.eql(u8, msg_type, "detach_session_response")) {
            const status = payload.get("status").?.string;
            if (std.mem.eql(u8, status, "ok")) {
                cleanupClientFdFile(ctx);
                _ = posix.write(posix.STDERR_FILENO, "\r\nDetached from session\r\n") catch {};
                return cleanup(ctx, completion);
            }
        } else if (std.mem.eql(u8, msg_type, "detach_notification")) {
            cleanupClientFdFile(ctx);
            _ = posix.write(posix.STDERR_FILENO, "\r\nDetached from session (external request)\r\n") catch {};
            return cleanup(ctx, completion);
        } else if (std.mem.eql(u8, msg_type, "kill_notification")) {
            cleanupClientFdFile(ctx);
            _ = posix.write(posix.STDERR_FILENO, "\r\nSession killed\r\n") catch {};
            return cleanup(ctx, completion);
        } else if (std.mem.eql(u8, msg_type, "pty_out")) {
            const text = payload.get("text").?.string;
            _ = posix.write(posix.STDOUT_FILENO, text) catch {};
        } else {
            std.debug.print("Unknown message type: {s}\n", .{msg_type});
        }

        return .rearm;
    } else |err| {
        std.debug.print("read failed: {s}\n", .{@errorName(err)});
    }

    ctx.allocator.destroy(read_ctx);
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
    const request = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"type\":\"detach_session_request\",\"payload\":{{\"session_name\":\"{s}\"}}}}\n",
        .{ctx.session_name},
    ) catch return;
    defer ctx.allocator.free(request);

    const write_ctx = ctx.allocator.create(StdinWriteContext) catch return;
    write_ctx.* = .{
        .allocator = ctx.allocator,
        .message = ctx.allocator.dupe(u8, request) catch return,
    };

    const write_completion = ctx.allocator.create(xev.Completion) catch return;
    ctx.stream.write(ctx.loop, write_completion, .{ .slice = write_ctx.message }, StdinWriteContext, write_ctx, stdinWriteCallback);
}

fn sendPtyInput(ctx: *Context, data: []const u8) void {
    var msg_buf = std.ArrayList(u8).initCapacity(ctx.allocator, 4096) catch return;
    defer msg_buf.deinit(ctx.allocator);

    msg_buf.appendSlice(ctx.allocator, "{\"type\":\"pty_in\",\"payload\":{\"text\":\"") catch return;

    for (data) |byte| {
        switch (byte) {
            '"' => msg_buf.appendSlice(ctx.allocator, "\\\"") catch return,
            '\\' => msg_buf.appendSlice(ctx.allocator, "\\\\") catch return,
            '\n' => msg_buf.appendSlice(ctx.allocator, "\\n") catch return,
            '\r' => msg_buf.appendSlice(ctx.allocator, "\\r") catch return,
            '\t' => msg_buf.appendSlice(ctx.allocator, "\\t") catch return,
            0x08 => msg_buf.appendSlice(ctx.allocator, "\\b") catch return,
            0x0C => msg_buf.appendSlice(ctx.allocator, "\\f") catch return,
            0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => {
                const escaped = std.fmt.allocPrint(ctx.allocator, "\\u{x:0>4}", .{byte}) catch return;
                defer ctx.allocator.free(escaped);
                msg_buf.appendSlice(ctx.allocator, escaped) catch return;
            },
            else => msg_buf.append(ctx.allocator, byte) catch return,
        }
    }

    msg_buf.appendSlice(ctx.allocator, "\"}}\n") catch return;

    const owned_message = ctx.allocator.dupe(u8, msg_buf.items) catch return;

    const write_ctx = ctx.allocator.create(StdinWriteContext) catch return;
    write_ctx.* = .{
        .allocator = ctx.allocator,
        .message = owned_message,
    };

    const write_completion = ctx.allocator.create(xev.Completion) catch return;
    ctx.stream.write(ctx.loop, write_completion, .{ .slice = owned_message }, StdinWriteContext, write_ctx, stdinWriteCallback);
}

const StdinWriteContext = struct {
    allocator: std.mem.Allocator,
    message: []u8,
};

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

        // Detect Ctrl-b (0x02) as prefix for detach command
        if (len == 1 and data[0] == 0x02) {
            ctx.prefix_pressed = true;
            return .rearm;
        }

        // If prefix was pressed and now we got 'd', detach
        if (ctx.prefix_pressed and len == 1 and data[0] == 'd') {
            ctx.prefix_pressed = false;
            sendDetachRequest(ctx);
            return .rearm;
        }

        // If prefix was pressed but we got something else, send the prefix and the new data
        if (ctx.prefix_pressed) {
            ctx.prefix_pressed = false;
            // Send the Ctrl-b that was buffered
            const prefix_data = [_]u8{0x02};
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
    ctx.allocator.destroy(completion);
    ctx.allocator.destroy(ctx);
    loop.stop();
    return .disarm;
}
