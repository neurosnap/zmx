const std = @import("std");
const posix = std.posix;
const xevg = @import("xev");
const xev = xevg.Dynamic;
const clap = @import("clap");
const builtin = @import("builtin");

const Config = @import("config.zig");
const protocol = @import("protocol.zig");

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

// stores all the necessary data for managing clients and pty sessions
const Daemon = struct {
    cfg: *Config,
    accept_completion: xev.Completion,
    server_fd: std.posix.fd_t,
    allocator: std.mem.Allocator,
    clients: std.AutoHashMap(std.posix.fd_t, *Client),
    sessions: std.StringHashMap(*Session),

    pub fn init(cfg: *Config, allocator: std.mem.Allocator, server_fd: std.posix.fd_t) *Daemon {
        var ctx = Daemon{
            .cfg = cfg,
            .accept_completion = .{},
            .allocator = allocator,
            .clients = std.AutoHashMap(std.posix.fd_t, *Client).init(allocator),
            .sessions = std.StringHashMap(*Session).init(allocator),
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
            .daemon = self,
            .fd = client_fd,
            .allocator = self.allocator,
            .stream = stream,
            .read_buffer = undefined,
            .msg_buffer = msg_buffer,
            .session = null,
        };

        try self.clients.put(client.fd, client);
        return client;
    }

    pub fn attach(self: *Daemon, client: *Client, req: protocol.AttachSessionRequest) !*Session {
        const is_reattach = self.sessions.contains(req.session_name);
        const session = if (is_reattach) blk: {
            std.log.info("reattaching to session: {s} {d}x{d}\n", .{ req.session_name, req.rows, req.cols });
            break :blk self.sessions.get(req.session_name).?;
        } else blk: {
            std.log.info("creating new session: {s} {d}x{d} {s}\n", .{ req.session_name, req.rows, req.cols, req.cwd });
            const new_session = try Session.init(self.allocator, req);
            try self.sessions.put(req.session_name, new_session);
            break :blk new_session;
        };

        client.session = session.name;
        try session.attached_clients.put(client.fd, {});
        const response = protocol.AttachSessionResponse{
            .status = "ok",
            .client_fd = client.fd,
        };
        try protocol.writeJson(self.allocator, client.fd, .attach_session_response, response);
        return session;
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
    daemon: *Daemon,
    fd: std.posix.fd_t,
    stream: xev.Stream,
    allocator: std.mem.Allocator,
    read_buffer: [128 * 1024]u8, // 128KB for high-throughput socket reads
    msg_buffer: std.ArrayList(u8),
    // TODO: session -> session_name
    session: ?[]const u8,

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

    fn handle_frame(self: *Client, msg: FrameData) !?*Session {
        if (msg.type == protocol.FrameType.pty_binary) {
            const session_name = self.session orelse {
                std.log.err("self fd={d} not attached to any session\n", .{self.fd});
                return error.NotAttached;
            };

            const session = self.daemon.sessions.get(session_name) orelse {
                std.log.err("session {s} not found\n", .{session_name});
                return error.SessionNotFound;
            };

            // Write input to PTY master fd
            _ = try posix.write(session.pty_master_fd, msg.payload);
        } else {
            const type_parsed = try protocol.parseMessageType(self.allocator, msg.payload);
            defer type_parsed.deinit();

            const msg_type = protocol.MessageType.fromString(type_parsed.value.type).?;
            switch (msg_type) {
                .attach_session_request => {
                    const parsed = try protocol.parseMessage(protocol.AttachSessionRequest, self.allocator, msg.payload);
                    // TODO: defer parsed.deint();
                    std.log.info(
                        "handling attach request for session: {s} ({}x{}) cwd={s}\n",
                        .{ parsed.value.payload.session_name, parsed.value.payload.cols, parsed.value.payload.rows, parsed.value.payload.cwd },
                    );
                    const session = try self.daemon.attach(self, parsed.value.payload);
                    return session;
                },
                else => {
                    std.log.err("unhandled message type: {s}\n", .{type_parsed.value.type});
                },
            }
        }

        return null;
    }
};

const Session = struct {
    name: []const u8,
    pty_master_fd: std.posix.fd_t,
    child_pid: std.posix.fd_t,
    created_at: i64,
    allocator: std.mem.Allocator,
    attached_clients: std.AutoHashMap(std.posix.fd_t, void),
    pty_read_buffer: [128 * 1024]u8, // 128KB for high-throughput PTY output

    fn init(alloc: std.mem.Allocator, req: protocol.AttachSessionRequest) !*Session {
        var master_fd: c_int = undefined;
        const pid = c.forkpty(&master_fd, null, null, null);
        if (pid < 0) {
            return error.ForkPtyFailed;
        }

        if (pid == 0) { // child pid code path
            const session_env = try std.fmt.allocPrint(alloc, "ZMX_SESSION={s}\x00", .{req.session_name});
            _ = c.putenv(@ptrCast(session_env.ptr));

            const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
            const argv = [_:null]?[*:0]const u8{ shell, null };
            const err = std.posix.execveZ(shell, &argv, std.c.environ);
            std.log.err("execve failed: {s}\n", .{@errorName(err)});
            std.posix.exit(1);
        }
        // master pid code path

        std.log.info("created pty session: name={s} master_pid={d} child_pid={d}\n", .{ req.session_name, master_fd, pid });

        // make pty non-blocking
        const flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(master_fd, posix.F.SETFL, flags | @as(u32, 0o4000));

        const session = try alloc.create(Session);

        // TODO: init ghostty

        session.* = .{
            .name = try alloc.dupe(u8, req.session_name),
            .created_at = std.time.timestamp(),

            .allocator = alloc,
            .pty_master_fd = @intCast(master_fd),
            .child_pid = pid,
            .attached_clients = std.AutoHashMap(std.posix.fd_t, void).init(alloc),
            .pty_read_buffer = undefined,
        };
        return session;
    }

    fn deinit(self: *Session) void {
        self.allocator.free(self.name);
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

const ReadPty = struct{
    client: *Client,
    session: *Session,
};

fn readCallback(
    client_opt: ?*Client,
    loop: *xev.Loop,
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
            return closeClient(loop, client, read_compl);
        };

        while (client.next_msg()) |msg| {
            std.log.info("msg_type: {d}\n", .{msg.type});
            const session_opt = client.handle_frame(msg) catch |err| {
                std.log.err("handle frame error: {s}\n", .{@errorName(err)});
                return closeClient(loop, client, read_compl);
            };
            if (session_opt) |session| {
                const stream = xev.Stream.initFd(session.pty_master_fd);
                const read_pty_compl = client.allocator.create(xev.Completion) catch |err| {
                    std.log.err("could not allocate completion: {s}\n", .{@errorName(err)});
                    return .disarm;
                };
                const read_pty = client.allocator.create(ReadPty) catch |err| {
                    std.log.err("could not allocate read pty: {s}\n", .{@errorName(err)});
                    return .disarm;
                };
                read_pty.* = .{
                    .client = client,
                    .session = session,
                };
                stream.read(
                    loop,
                    read_pty_compl,
                    .{ .slice = &session.pty_read_buffer },
                    ReadPty,
                    read_pty,
                    readPtyCallback,
                );
            }
        } else |err| {
            std.log.err("could not get next client msg: {s}\n", .{@errorName(err)});
            return closeClient(loop, client, read_compl);
        }
    } else |err| {
        std.log.err("no read result: {s}\n", .{@errorName(err)});
        client.allocator.destroy(read_compl);
        return .disarm;
    }
    return .rearm;
}

const WritePty = struct{
    alloc: std.mem.Allocator,
    msg: []u8,
};

fn readPtyCallback(
    pty_ctx_opt: ?*ReadPty,
    loop: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    read_buffer: xev.ReadBuffer,
    read_result: xev.ReadError!usize,
) xev.CallbackAction {
    const ctx = pty_ctx_opt.?;
    const client = ctx.client;
    const daemon = client.daemon;
    const session = daemon.sessions.get(ctx.session.name) orelse {
        std.log.err("session {s} not found\n", .{ctx.session.name});
        client.allocator.destroy(ctx);
        client.allocator.destroy(completion);
        return .disarm;
    };

    if (read_result) |bytes_read| {
        if (bytes_read == 0) {
            std.log.err("session {s} pty eof\n", .{ctx.session.name});
            client.allocator.destroy(ctx);
            client.allocator.destroy(completion);
            return .disarm;
        }

        const data = read_buffer.slice[0..bytes_read];
        std.log.info("pty output: {s} bytes\n", .{bytes_read});

        // TODO: ghostty stream nextSlice

        if (session.attached_clients.count() > 0 and data.len > 0) {
            // Send PTY output as binary frame to avoid JSON escaping issues
            // Frame format: [4-byte length][2-byte type][payload]
            const header = protocol.FrameHeader{
                .length = @intCast(data.len),
                .frame_type = @intFromEnum(protocol.FrameType.pty_binary),
            };

            const frame_size = @sizeOf(protocol.FrameHeader) + data.len;
            var frame_buf = std.ArrayList(u8).initCapacity(session.allocator, frame_size) catch |err| {
                std.log.err("cannot allocate frame buffer: {s}\n", .{@errorName(err)});
                client.allocator.destroy(ctx);
                client.allocator.destroy(completion);
                return .disarm;
            };
            defer frame_buf.deinit(session.allocator);

            const header_bytes = std.mem.asBytes(&header);
            frame_buf.appendSlice(session.allocator, header_bytes) catch |err| {
                std.log.err("cannot append frame buffer with header: {s}\n", .{@errorName(err)});
                client.allocator.destroy(ctx);
                client.allocator.destroy(completion);
                return .disarm;
            };
            frame_buf.appendSlice(session.allocator, data) catch |err| {
                std.log.err("cannot append frame buffer with data: {s}\n", .{@errorName(err)});
                client.allocator.destroy(ctx);
                client.allocator.destroy(completion);
                return .disarm;
            };

            var it = session.attached_clients.keyIterator();
            while (it.next()) |client_fd| {
                const attached_client = daemon.clients.get(client_fd.*) orelse continue;
                const owned_frame = session.allocator.dupe(u8, frame_buf.items) catch continue;

                const write_ctx = session.allocator.create(WritePty) catch {
                    session.allocator.free(owned_frame);
                    continue;
                };
                write_ctx.* = .{
                    .alloc = session.allocator,
                    .msg = owned_frame,
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
                    WritePty,
                    write_ctx,
                    writePtyCallback,
                );
            }
        }

        return .rearm;
    } else |err| {
        if (err == error.WouldBlock) {
            return .rearm;
        }
        client.allocator.destroy(ctx);
        client.allocator.destroy(completion);
        return .disarm;
    }
    unreachable;
}

fn writePtyCallback(
    write_ctx_opt: ?*WritePty,
    _: *xev.Loop,
    completion: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    write_result: xev.WriteError!usize,
) xev.CallbackAction {
    const write_ctx = write_ctx_opt.?;
    const allocator = write_ctx.alloc;

    if (write_result) |_| {
        // Successfully sent PTY output to client
    } else |_| {
        // Silently ignore write errors to prevent log spam
    }
    allocator.free(write_ctx.msg);
    allocator.destroy(write_ctx);
    allocator.destroy(completion);
    return .disarm;
}

fn closeClient(loop: *xev.Loop, client: *Client, completion: *xev.Completion) xev.CallbackAction {
    std.debug.print("closing client fd={d}\n", .{client.fd});

    // Remove client from attached session if any
    if (client.session) |session_name| {
        if (client.daemon.sessions.get(session_name)) |session| {
            _ = session.attached_clients.remove(client.fd);
            std.debug.print("removed client fd={d} from session {s} attached_clients\n", .{ client.fd, session_name });
        }
    }

    // Remove client from the clients map
    _ = client.daemon.clients.remove(client.fd);

    // Initiate async close of the client stream
    const close_completion = client.allocator.create(xev.Completion) catch {
        // If we can't allocate, just clean up synchronously
        posix.close(client.fd);
        client.allocator.destroy(completion);
        client.allocator.destroy(client);
        return .disarm;
    };

    client.stream.close(loop, close_completion, Client, client, closeCallback);
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
    client.msg_buffer.deinit(client.allocator);
    client.allocator.destroy(completion);
    client.allocator.destroy(client);
    return .disarm;
}
