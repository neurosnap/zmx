const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("../ipc.zig");
const cross = @import("../cross.zig");
const util = @import("../util.zig");
const log = @import("../log.zig");
const socket = @import("../socket.zig");
const ClientMod = @import("../Client.zig");
const Cfg = @import("../Cfg.zig").Cfg;
const shared = @import("shared.zig");

const Client = ClientMod.Client;

pub const ClientMsgAction = enum {
    next,
    done,
    kill,
};

pub const EnsureSessionResult = struct {
    created: bool,
    is_daemon: bool,
};

pub const Daemon = struct {
    cfg: *Cfg,
    alloc: std.mem.Allocator,
    clients: std.ArrayList(*Client),
    leader_client_fd: ?i32,
    session_name: []const u8,
    socket_path: []const u8,
    running: bool,
    pid: i32,
    command: ?[]const []const u8 = null,
    cwd: []const u8 = "",
    has_pty_output: bool = false,
    has_had_client: bool = false,
    has_terminal_client: bool = false,
    created_at: u64,
    is_task_mode: bool = false,
    task_exit_code: ?u8 = null,
    task_ended_at: ?u64 = null,
    pty_fd: i32 = -1,
    pty_write_buf: std.ArrayList(u8) = .empty,

    const PTY_WRITE_BUF_MAX = 256 * 1024;

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
        if (self.leader_client_fd == client.socket_fd) {
            std.log.info("unsetting leader session={s} fd={d}", .{ self.session_name, client.socket_fd });
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
        try ipc.appendMessage(self.alloc, &client.write_buf, .Resize, "");
        client.has_pending_output = true;
    }

    fn execChild(self: *Daemon) !noreturn {
        const alloc = std.heap.c_allocator;
        const dfl: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.PIPE, &dfl, null);

        const session_env = try std.fmt.allocPrintSentinel(alloc, "ZMX_SESSION={s}", .{self.session_name}, 0);
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
        const login_shell = try std.fmt.allocPrintSentinel(alloc, "-{s}", .{std.fs.path.basename(shell)}, 0);
        const argv = [_:null]?[*:0]const u8{ login_shell, null };
        const err = std.posix.execvpeZ(shell, &argv, std.c.environ);
        std.log.err("execvpe failed: shell={s} err={s}", .{ shell, @errorName(err) });
        std.posix.exit(1);
    }

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
        if (pid < 0) return error.ForkPtyFailed;

        if (pid == 0) {
            execChild(self) catch |err| {
                std.log.err("child setup failed: {s}", .{@errorName(err)});
                std.posix.exit(1);
            };
            unreachable;
        }

        self.pid = pid;
        std.log.info("pty spawned session={s} pid={d}", .{ self.session_name, pid });

        const flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(master_fd, posix.F.SETFL, flags | shared.O_NONBLOCK);
        return master_fd;
    }

    fn isSessionAvailable(self: *Daemon, dir: std.fs.Dir) bool {
        if (ipc.connectSession(self.socket_path)) |fd| {
            posix.close(fd);
            if (self.command != null) {
                std.log.warn("session already exists, ignoring command session={s}", .{self.session_name});
            }
        } else |err| switch (err) {
            error.ConnectionRefused => {
                socket.cleanupStaleSocket(dir, self.session_name);
                return false;
            },
            else => {
                std.log.warn("connect failed ({s}), proceeding to attach session={s}", .{ @errorName(err), self.session_name });
            },
        }
        return true;
    }

    fn createNewSession(self: *Daemon, dir: std.fs.Dir) !EnsureSessionResult {
        std.log.info("creating session={s}", .{self.session_name});
        const server_sock_fd = try socket.createSocket(self.socket_path);

        const pid = try posix.fork();
        if (pid == 0) {
            _ = try posix.setsid();
            shared.log_system.deinit();

            {
                const devnull = std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch |err| {
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

            {
                const dir_fd = @as(i32, @intCast(dir.fd));
                var fd: i32 = 3;
                while (fd < 64) : (fd += 1) {
                    if (fd == server_sock_fd or fd == dir_fd) continue;
                    _ = std.c.close(fd);
                }
            }

            const log_path = std.fs.path.join(std.heap.c_allocator, &.{ self.cfg.log_dir, "zmx.log" }) catch |err| {
                std.log.warn("failed to join log path: {s}", .{@errorName(err)});
                return err;
            };
            shared.log_system.init(std.heap.c_allocator, log_path, self.cfg.log_mode) catch |err| {
                std.log.warn("failed to init log system: {s}", .{@errorName(err)});
                return err;
            };
            std.log.info("daemon started session={s}", .{self.session_name});

            const pty_fd = self.spawnPty() catch |err| {
                std.log.err("spawnPty failed: {s}", .{@errorName(err)});
                std.posix.exit(1);
            };
            daemonLoop(self, server_sock_fd, pty_fd);

            std.log.info("daemon exiting session={s}", .{self.session_name});
            posix.close(pty_fd);
            posix.close(server_sock_fd);
            socket.cleanupStaleSocket(dir, self.session_name);
            std.posix.exit(0);
        }

        posix.close(server_sock_fd);
        self.pid = pid;
        return .{ .created = true, .is_daemon = false };
    }

    pub fn ensureSession(self: *Daemon) !EnsureSessionResult {
        var dir = try std.fs.openDirAbsolute(self.cfg.socket_dir, .{});
        defer dir.close();

        const exists = try socket.sessionExists(dir, self.session_name);
        const should_create = !(exists and self.isSessionAvailable(dir));

        if (should_create) {
            return self.createNewSession(dir);
        }

        return .{ .created = false, .is_daemon = false };
    }

    fn queuePtyInput(self: *Daemon, data: []const u8) void {
        if (data.len == 0) return;
        if (self.pty_write_buf.items.len + data.len > PTY_WRITE_BUF_MAX) {
            std.log.warn("pty input dropped {d} bytes (buffer full, shell not reading)", .{data.len});
            return;
        }
        std.log.debug("buffering pty input data={x}", .{data});
        self.pty_write_buf.appendSlice(self.alloc, data) catch |err| {
            std.log.warn("pty input dropped {d} bytes: {s}", .{ data.len, @errorName(err) });
        };
    }

    pub fn handleInput(self: *Daemon, client: *Client, payload: []const u8) !void {
        std.log.debug("buffering pty input data={x}", .{payload});
        if (self.leader_client_fd == client.socket_fd) {
            self.queuePtyInput(payload);
            return;
        }
        if (util.isUserInput(payload)) {
            try self.setLeader(client);
            self.queuePtyInput(payload);
        }
    }

    pub fn handleSwitch(self: *Daemon, session_name: []const u8) !void {
        for (self.clients.items) |client| {
            if (self.leader_client_fd != client.socket_fd) continue;
            ipc.appendMessage(self.alloc, &client.write_buf, .Switch, session_name) catch |err| {
                std.log.warn("failed to buffer terminal state for client err={s}", .{@errorName(err)});
            };
            client.has_pending_output = true;
            return;
        }
        return error.NoLeaderFound;
    }

    pub fn handleInit(self: *Daemon, client: *Client, pty_fd: i32, term: *ghostty_vt.Terminal, payload: []const u8) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;

        if (self.has_pty_output and self.has_had_client) {
            const cursor = &term.screens.active.cursor;
            std.log.debug("cursor before serialize: x={d} y={d} pending_wrap={}", .{ cursor.x, cursor.y, cursor.pending_wrap });
            if (util.serializeTerminalState(self.alloc, term)) |term_output| {
                std.log.debug("serialize terminal state", .{});
                const restore_data = util.rewritePromptRedraw(self.alloc, term_output) orelse term_output;
                defer self.alloc.free(term_output);
                defer if (restore_data.ptr != term_output.ptr) self.alloc.free(restore_data);
                ipc.appendMessage(self.alloc, &client.write_buf, .Output, restore_data) catch |err| {
                    std.log.warn("failed to buffer terminal state for client err={s}", .{@errorName(err)});
                };
                client.has_pending_output = true;
            }
        }

        if (self.leader_client_fd == null) try self.setLeader(client);

        if (self.leader_client_fd == client.socket_fd) {
            const resize = std.mem.bytesToValue(ipc.Resize, payload);
            var ws: cross.c.struct_winsize = .{
                .ws_row = resize.rows,
                .ws_col = resize.cols,
                .ws_xpixel = resize.xpixel,
                .ws_ypixel = resize.ypixel,
            };
            _ = cross.c.ioctl(pty_fd, cross.c.TIOCSWINSZ, &ws);
            const saved_prompt_redraw = term.flags.shell_redraws_prompt;
            term.flags.shell_redraws_prompt = .false;
            defer term.flags.shell_redraws_prompt = saved_prompt_redraw;
            try term.resize(self.alloc, resize.cols, resize.rows);
            self.has_had_client = true;
            self.has_terminal_client = true;
            std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });
        }
    }

    pub fn handleResize(self: *Daemon, client: *Client, pty_fd: i32, term: *ghostty_vt.Terminal, payload: []const u8) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;
        if (self.leader_client_fd == null) try self.setLeader(client);
        if (self.leader_client_fd != client.socket_fd) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        var ws: cross.c.struct_winsize = .{
            .ws_row = resize.rows,
            .ws_col = resize.cols,
            .ws_xpixel = resize.xpixel,
            .ws_ypixel = resize.ypixel,
        };
        _ = cross.c.ioctl(pty_fd, cross.c.TIOCSWINSZ, &ws);
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
        var info = std.mem.zeroes(ipc.Info);
        info.clients_len = self.clients.items.len - 1;
        info.pid = self.pid;
        info.created_at = self.created_at;
        info.task_ended_at = self.task_ended_at orelse 0;
        info.task_exit_code = self.task_exit_code orelse 0;

        const cur_cmd = self.command;
        if (cur_cmd) |args| {
            for (args, 0..) |arg, i| {
                const quoted = if (util.shellNeedsQuoting(arg)) util.shellQuote(self.alloc, arg) catch null else null;
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

    pub fn handleHistory(self: *Daemon, client: *Client, term: *ghostty_vt.Terminal, payload: []const u8) !void {
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
        self.task_exit_code = null;
        self.task_ended_at = null;
        self.is_task_mode = true;

        if (payload.len == 0) return;

        const cmd = payload;

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
        if (payload.len < @sizeOf(u32)) return error.InvalidPayload;
        const path_len = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]);
        if (payload.len < @sizeOf(u32) + path_len) return error.InvalidPayload;
        const file_path = payload[@sizeOf(u32)..][0..path_len];
        const file_content = payload[@sizeOf(u32) + path_len ..];

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
        std.log.debug("write command len={d} file_path={s}", .{ file_content.len, file_path });
    }
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
    try poll_fds.append(alloc, .{ .fd = shared.sig_pipe[0], .events = posix.POLL.IN, .revents = 0 });

    for (clients) |client| {
        var events: i16 = posix.POLL.IN;
        if (client.has_pending_output) events |= posix.POLL.OUT;
        try poll_fds.append(alloc, .{ .fd = client.socket_fd, .events = events, .revents = 0 });
    }
}

fn handlePtyRead(daemon: *Daemon, pty_fd: i32, vt_stream: *ghostty_vt.TerminalStream, revents: i16) bool {
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

fn processClientMessages(daemon: *Daemon, client: *Client, i: usize, pty_fd: i32, vt_stream: *ghostty_vt.TerminalStream, term: *ghostty_vt.Terminal) !ClientMsgAction {
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

fn processClientEvents(daemon: *Daemon, poll_fds: *const std.ArrayList(posix.pollfd), term: *ghostty_vt.Terminal, vt_stream: *ghostty_vt.TerminalStream, pty_fd: i32) !bool {
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
            if (n > 0) client.write_buf.replaceRange(daemon.alloc, 0, n, &[_]u8{}) catch unreachable;
            if (client.write_buf.items.len == 0) client.has_pending_output = false;
        }

        if (revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
            const last = daemon.closeClient(client, i, false);
            if (last) return true;
        }
    }
    return false;
}

fn daemonLoop(daemon: *Daemon, server_sock_fd: i32, pty_fd: i32) void {
    std.log.info("daemon started session={s} pty_fd={d}", .{ daemon.session_name, pty_fd });
    daemon.pty_fd = pty_fd;
    shared.openSignalPipe() catch return;
    shared.installWakeHandler(posix.SIG.TERM);

    var poll_fds = std.ArrayList(posix.pollfd).initCapacity(daemon.alloc, 8) catch return;
    defer poll_fds.deinit(daemon.alloc);

    const init_size = ipc.getTerminalSize(pty_fd);
    var term = ghostty_vt.Terminal.init(daemon.alloc, .{
        .cols = init_size.cols,
        .rows = init_size.rows,
        .max_scrollback = daemon.cfg.max_scrollback,
    }) catch return;
    defer term.deinit(daemon.alloc);
    var vt_stream = term.vtStream();
    defer vt_stream.deinit();

    std.debug.assert(server_sock_fd >= 0);
    std.debug.assert(pty_fd >= 0);

    while (daemon.running) {
        fillDaemonPollFds(daemon.alloc, &poll_fds, server_sock_fd, pty_fd, daemon.pty_write_buf.items, daemon.clients.items) catch continue;
        _ = posix.poll(poll_fds.items, -1) catch continue;

        if (poll_fds.items[2].revents & posix.POLL.IN != 0) {
            shared.drainSignalPipe();
            std.log.info("SIGTERM received, shutting down gracefully session={s}", .{daemon.session_name});
            break;
        }

        if (acceptClient(daemon, server_sock_fd, poll_fds.items[0].revents) catch true) break;
        if (handlePtyRead(daemon, pty_fd, &vt_stream, poll_fds.items[1].revents)) break;
        flushPtyWrite(daemon, pty_fd, poll_fds.items[1].revents);
        if (processClientEvents(daemon, &poll_fds, &term, &vt_stream, pty_fd) catch true) break;
    }
}
