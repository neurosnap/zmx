const std = @import("std");
const posix = std.posix;
const xevg = @import("xev");
const xev = xevg.Dynamic;
const clap = @import("clap");
const builtin = @import("builtin");
const ghostty = @import("ghostty-vt");

const Config = @import("config.zig");
const protocol = @import("protocol.zig");
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

const Daemon = struct {
    cfg: *Config,
    accept_completion: xev.Completion,
    server_fd: std.posix.fd_t,
    allocator: std.mem.Allocator,
    clients: std.AutoHashMap(std.posix.fd_t, *Client),

    pub fn init(cfg: *Config, allocator: std.mem.Allocator, server_fd: std.posix.fd_t) *Daemon {
        var ctx = Daemon{
            .cfg = cfg,
            .accept_completion = .{},
            .allocator = allocator,
            .clients = std.AutoHashMap(std.posix.fd_t, *Client).init(allocator),
            .server_fd = server_fd,
        };
        return &ctx;
    }

    pub fn deinit(self: *Daemon) void {
        self.clients.deinit();
    }

    pub fn accept(self: *Daemon) !*Client {
        // SOCK.CLOEXEC: Close socket on exec to prevent child PTY processes from inheriting client connections
        // SOCK.NONBLOCK: Make client socket non-blocking for async I/O
        const client_fd = posix.accept(self.server_fd, null, null, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK) catch |err| {
            return err;
        };
        const client = self.allocator.create(Client) catch |err| {
            return err;
        };
        const stream = xev.Stream.initFd(client_fd);
        const msg_buffer = std.ArrayList(u8).initCapacity(self.allocator, 128 * 1024) catch |err| {
            return err;
        };
        client.* = .{
            .fd = client_fd,
            .allocator = self.allocator,
            .stream = stream,
            .read_buffer = undefined,
            .msg_buffer = msg_buffer,
        };

        try self.clients.put(client.fd, client);
        return client;
    }
};

const FrameError = error{
    Incomplete,
    OutOfMemory,
};

const FrameData = struct {
    type: protocol.FrameType,
    payload: []const u8,
};

const Client = struct {
    fd: std.posix.fd_t,
    stream: xev.Stream,
    allocator: std.mem.Allocator,
    read_buffer: [128 * 1024]u8, // 128KB for high-throughput socket reads
    msg_buffer: std.ArrayList(u8),

    pub fn next_msg(self: *Client) FrameError!FrameData {
        const msg: *std.ArrayList(u8) = &self.msg_buffer;
        const header_size = @sizeOf(protocol.FrameHeader);
        if (msg.items.len < header_size) {
            // incomplete frame, wait for more data
            return FrameError.Incomplete;
        }
        const header: *const protocol.FrameHeader = @ptrCast(@alignCast(msg.items.ptr));
        const expected_total = header_size + header.length;
        if (msg.items.len < expected_total) {
            // incomplete frame, wait for more data
            return FrameError.Incomplete;
        }
        const payload = msg.items[header_size..expected_total];

        // Remove processed message from buffer
        const remaining = msg.items[expected_total..];
        const remaining_copy = self.allocator.dupe(u8, remaining) catch |err| {
            return err;
        };
        msg.clearRetainingCapacity();
        msg.appendSlice(self.allocator, remaining_copy) catch |err| {
            self.allocator.free(remaining_copy);
            return err;
        };
        self.allocator.free(remaining_copy);

        return .{
            .type = @enumFromInt(header.frame_type),
            .payload = payload,
        };
    }
};

pub fn main(cfg: *Config, alloc: std.mem.Allocator) !void {
    var thread_pool = xevg.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    std.log.info("zmx daemon starting\n", .{});
    std.log.info("socket_path: {s}\n", .{cfg.socket_path});

    std.log.info("deleting previous socket file\n", .{});
    _ = std.fs.cwd().deleteFile(cfg.socket_path) catch {};

    // AF.UNIX: Unix domain socket for local IPC with client processes
    // SOCK.STREAM: Reliable, bidirectional communication for JSON protocol messages
    // SOCK.NONBLOCK: Prevents blocking to work with libxev's async event loop
    const server_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    defer {
        posix.close(server_fd);
        std.log.info("deleting socket file\n", .{});
        std.fs.cwd().deleteFile(cfg.socket_path) catch {};
    }

    var unix_addr = std.net.Address.initUnix(cfg.socket_path) catch |err| {
        std.debug.print("initUnix failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try posix.bind(server_fd, &unix_addr.any, unix_addr.getOsSockLen());
    try posix.listen(server_fd, 128);

    var daemon = Daemon.init(cfg, alloc, server_fd);
    defer daemon.deinit();

    const daemon_stream = xev.Stream.initFd(server_fd);
    daemon_stream.poll(
        &loop,
        &daemon.accept_completion,
        .read,
        Daemon,
        daemon,
        acceptCallback,
    );

    try loop.run(.until_done);
}

fn acceptCallback(
    daemon_opt: ?*Daemon,
    loop: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    poll_result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const daemon = daemon_opt.?;
    if (poll_result) |_| {
        while (true) {
            if (daemon.accept()) |client| {
                const read_completion = client.allocator.create(xev.Completion) catch |err| {
                    std.log.err("cannot read from client: {s}\n", .{@errorName(err)});
                    continue;
                };
                client.stream.read(
                    loop,
                    read_completion,
                    .{ .slice = &client.read_buffer },
                    Client,
                    client,
                    readCallback,
                );
            } else |err| {
                if (err == error.WouldBlock) {
                    std.log.err("failed to accept client: {s}\n", .{@errorName(err)});
                    break;
                }
            }
        }
    } else |err| {
        std.log.err("accepting socket connection failed: {s}\n", .{@errorName(err)});
    }

    return .rearm;
}

fn readCallback(
    client_opt: ?*Client,
    _: *xev.Loop,
    read_compl: *xev.Completion,
    _: xev.Stream,
    read_buffer: xev.ReadBuffer,
    read_result: xev.ReadError!usize,
) xev.CallbackAction {
    const client = client_opt.?;
    if (read_result) |read_len| {
        const data = read_buffer.slice[0..read_len];
        client.msg_buffer.appendSlice(client.allocator, data) catch |err| {
            std.log.err("cannot append to message buffer: {s}\n", .{@errorName(err)});
            client.allocator.destroy(read_compl);
            return .disarm;
        };

        while (client.next_msg()) |msg| {
            std.log.info("msg_type: {d}\n", .{msg.type});
        } else |err| {
            std.log.err("could not get next client msg: {s}\n", .{@errorName(err)});
            // TODO: close client?
        }
    } else |err| {
        std.log.err("no read result: {s}\n", .{@errorName(err)});
        client.allocator.destroy(read_compl);
        return .disarm;
    }
    return .rearm;
}

// fn handleBinaryFrame(client: *Client, text: []const u8) !void {
//     const session_name = client.attached_session orelse {
//         std.debug.print("Client fd={d} not attached to any session\n", .{client.fd});
//         return error.NotAttached;
//     };
//
//     const session = client.server_ctx.sessions.get(session_name) orelse {
//         std.debug.print("Session {s} not found\n", .{session_name});
//         return error.SessionNotFound;
//     };
//
//     // Filter out terminal response sequences before writing to PTY
//     // var filtered_buf: [128 * 1024]u8 = undefined;
//     // const filtered_len = filterTerminalResponses(text, &filtered_buf);
//
//     // if (filtered_len == 0) {
//     //     return; // All input was filtered, nothing to write
//     // }
//     //
//     const filtered_len = client.msg_buffer.len;
//     const filtered_text = client.msg_buffer; // filtered_buf[0..filtered_len];
//     std.debug.print("Client fd={d}: Writing {d} bytes to PTY fd={d} (filtered from {d} bytes)\n", .{ client.fd, filtered_len, session.pty_master_fd, text.len });
//
//     // Write input to PTY master fd
//     const written = posix.write(session.pty_master_fd, filtered_text) catch |err| {
//         std.debug.print("Error writing to PTY: {s}\n", .{@errorName(err)});
//         return err;
//     };
//     _ = written;
// }
