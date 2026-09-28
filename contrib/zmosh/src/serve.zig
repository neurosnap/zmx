//! UDP gateway for the current core daemon's native IPC.
const std = @import("std");
const core = @import("zmx-core");
const p = core.posix;
const crypto = @import("crypto.zig");
const udp = @import("udp.zig");
const link_mod = @import("link.zig");
const wire = @import("wire.zig");
const runtime = @import("runtime.zig");

const pause_high = 768 * 1024;
const pause_low = 512 * 1024;
const pause_timeout = 2 * std.time.ns_per_s;

const Gateway = struct {
    const Phase = enum { awaiting_init, priming, streaming };
    phase: Phase = .awaiting_init,
    prime_started: i64 = 0,
    alloc: std.mem.Allocator,
    link: *link_mod.Link,
    frame: wire.NativeFrame = .{},
    output_cursor: usize = 0,
    native: link_mod.Queue = .{},
    size: ?core.ipc.Resize = null,
    resize_requested: bool = false,
    detached: bool = false,
    eof: bool = false,
    ended: bool = false,
    end_started: ?i64 = null,
    paused_since: ?i64 = null,
    native_progress: i64,

    fn deinit(self: *Gateway) void {
        self.frame.deinit(self.alloc);
        self.native.deinit(self.alloc);
    }

    fn appendRemote(self: *Gateway, msg: wire.Message) !bool {
        // Translation may append native + legacy size records. Reserve the
        // worst case before translating, then retain the whole result.
        if (self.native.room() < msg.data.len + 32) return false;
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(self.alloc);
        try wire.appendNative(self.alloc, &encoded, msg);
        try self.native.append(self.alloc, encoded.items);
        if (msg.tag == .Init or msg.tag == .Resize) self.size = try wire.decodeSize(msg.data);
        if (msg.tag == .Detach) self.detached = true;
        return true;
    }

    fn receiveRemote(self: *Gateway, now: i64) !void {
        if (self.phase == .priming) return;
        if (self.detached or self.eof) return;
        while (self.link.recv.peek()) |bytes| {
            const msg = try wire.decode(bytes);
            if (self.phase == .awaiting_init) {
                if (msg.tag != .Init) return error.InitialSizeRequired;
                // Core skips restoration on its first ever Init. Prime that
                // existing state on a provisional connection, then wait for
                // Detach's EOF processing barrier before reconnecting. Drop
                // all provisional output so an existing session restores once.
                if (!try self.appendRemote(msg)) break;
                var detach: std.ArrayList(u8) = .empty;
                defer detach.deinit(self.alloc);
                try core.ipc.appendMessage(self.alloc, &detach, .Detach, "");
                try self.native.append(self.alloc, detach.items);
                self.phase = .priming;
                self.prime_started = now;
                self.link.recv.pop();
                return;
            }
            if (!try self.appendRemote(msg)) break;
            self.link.recv.pop();
            if (self.detached) break;
        }
        if (self.resize_requested) {
            if (self.size) |size| {
                const bytes = wire.encodeSize(size);
                if (try self.appendRemote(.{ .tag = .Resize, .data = &bytes })) self.resize_requested = false;
            }
        }
    }

    fn forwardFrame(self: *Gateway) !void {
        if (self.phase != .streaming) return;
        const msg = (try self.frame.message()) orelse return;
        switch (msg.header.tag) {
            .Output => {
                // Keep a maximum-sized native snapshot in this single frame;
                // copy only chunks that fit the separately bounded send queue.
                while (self.output_cursor < msg.payload.len) {
                    const n = @min(link_mod.chunk_size, msg.payload.len - self.output_cursor);
                    if (self.link.outgoing.room() < wire.header_len + n) return;
                    try self.link.enqueue(.Output, msg.payload[self.output_cursor..][0..n]);
                    self.output_cursor += n;
                }
            },
            .Resize => {
                if (msg.payload.len != 0) return error.InvalidNativeResize;
                self.resize_requested = true;
            },
            .Switch => return error.UnsupportedSessionSwitch,
            // Informational records do not imply session termination and are
            // deliberately excluded from the remote terminal vocabulary.
            else => {},
        }
        self.frame.clear();
        self.output_cursor = 0;
    }

    fn readPaused(self: *Gateway, now: i64) !bool {
        const queued = self.link.outgoing.data().len;
        if (self.paused_since == null and queued >= pause_high) self.paused_since = now;
        if (self.paused_since) |start| {
            if (queued < pause_low) {
                self.paused_since = null;
            } else {
                if (now - start >= pause_timeout) return error.NativeReadPauseTimeout;
                return true;
            }
        }
        return false;
    }

    fn readNative(self: *Gateway, fd: i32) !void {
        if (self.phase == .priming) {
            // The provisional stream is discarded, including a truncated
            // snapshot when Detach closes the core client with queued bytes.
            for (0..64) |_| {
                var discard: [16 * 1024]u8 = undefined;
                const n = p.read(fd, &discard) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => return err,
                };
                if (n == 0) {
                    self.eof = true;
                    return;
                }
            }
            return;
        }
        // Reading exactly one frame's remainder ensures a cap-sized snapshot
        // cannot acquire another frame's bytes behind it.
        for (0..64) |_| {
            try self.forwardFrame();
            const remaining = try self.frame.remaining();
            if (remaining == 0) return;
            var buf: [16 * 1024]u8 = undefined;
            const n = p.read(fd, buf[0..@min(buf.len, remaining)]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) {
                if (self.frame.bytes.items.len != 0) return error.TruncatedNativeFrame;
                self.eof = true;
                return;
            }
            try self.frame.append(self.alloc, buf[0..n]);
            if (self.link.outgoing.data().len >= pause_high) return;
        }
    }

    fn finishPriming(self: *Gateway, fd: *i32, path: []const u8, now: i64) !void {
        std.debug.assert(self.phase == .priming and self.eof);
        if (self.native.data().len != 0) return error.InitializationClosedEarly;
        p.close(fd.*);
        fd.* = -1;
        const replacement = try core.socket.sessionConnect(path);
        errdefer p.close(replacement);
        _ = try runtime.nonblocking(replacement);
        const bytes = wire.encodeSize(self.size orelse return error.InitialSizeRequired);
        if (!try self.appendRemote(.{ .tag = .Init, .data = &bytes })) return error.QueueFull;
        fd.* = replacement;
        self.phase = .streaming;
        self.eof = false;
        self.resize_requested = false;
        self.native_progress = now;
    }

    fn writeNative(self: *Gateway, fd: i32, now: i64) !void {
        if (self.native.data().len == 0) {
            self.native_progress = now;
            return;
        }
        const n = p.write(fd, self.native.data()) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            self.native.consume(n);
            self.native_progress = now;
        } else if (now - self.native_progress >= link_mod.progress_timeout_ns) return error.NativeWriteTimeout;
    }
};

pub fn run(alloc: std.mem.Allocator, io: std.Io, raw_session: []const u8) !void {
    var cfg = try core.cfg.init(alloc, io);
    defer cfg.deinit(alloc);
    const session = try core.socket.getSeshName(alloc, raw_session);
    defer alloc.free(session);
    const path = try core.socket.getSocketPath(alloc, cfg.socket_dir, session);
    defer alloc.free(path);
    // A bootstrap without authenticated UDP must not leave an unread client
    // attached to the core's output broadcast queue.
    var native_fd: i32 = -1;
    defer if (native_fd >= 0) p.close(native_fd);
    const key = try crypto.generateKey(io);
    var socket = try udp.UdpSocket.bind(60000, 61000);
    var link = link_mod.Link.init(alloc, socket, key, .to_client, udp.nanoNow(io)) catch |err| {
        socket.close();
        return err;
    };
    defer link.deinit();
    try runtime.init();
    defer runtime.deinit();
    var bootstrap: [128]u8 = undefined;
    const encoded_key = crypto.keyToBase64(key);
    const record = try std.fmt.bufPrint(&bootstrap, "ZMX_CONNECT udp {d} {s}\n", .{ socket.bound_port, encoded_key });
    var written: usize = 0;
    while (written < record.len) written += try p.write(1, record[written..]);
    p.close(1); // Dedicated bootstrap pipe; no SSH descriptor survives this point.
    var gateway = Gateway{ .alloc = alloc, .link = &link, .native_progress = udp.nanoNow(io) };
    defer gateway.deinit();
    gatewayLoop(&gateway, io, &native_fd, path) catch |err| {
        // Disconnect before the bounded failure notification: retaining a
        // stopped native reader would allow the daemon's backlog to grow.
        if (native_fd >= 0) {
            p.close(native_fd);
            native_fd = -1;
        }
        // An existing terminal drain owns its original deadline. Starting a
        // second error drain would keep the peer alive beyond that bound.
        if (!gateway.ended) notifyFailure(&link, io, @errorName(err));
        return err;
    };
}

fn gatewayLoop(g: *Gateway, io: std.Io, fd: *i32, path: []const u8) !void {
    while (true) {
        const now = udp.nanoNow(io);
        try g.link.receive(now);
        if (g.phase == .priming) {
            if (now - g.prime_started >= link_mod.progress_timeout_ns) return error.InitializationTimeout;
            if (g.eof) try g.finishPriming(fd, path, now);
        }
        try g.receiveRemote(now);
        if (g.phase == .priming and fd.* < 0) {
            fd.* = try core.socket.sessionConnect(path);
            _ = try runtime.nonblocking(fd.*);
            g.native_progress = now;
        }
        try g.forwardFrame();
        const paused = try g.readPaused(now);
        if (g.phase == .streaming and g.eof and !g.ended and g.frame.bytes.items.len == 0 and g.link.outgoing.room() >= wire.header_len) {
            try g.link.enqueue(.SessionEnd, "");
            g.ended = true;
            g.end_started = now;
        }
        try g.link.tick(now);
        if (g.ended and g.link.idle()) return;
        if (g.end_started) |start| {
            if (now - start >= link_mod.drain_timeout_ns) return error.TerminationDrainTimeout;
        }
        const can_read = g.phase != .awaiting_init and !g.eof and !paused and g.link.peer.addr != null and (try g.frame.remaining()) != 0;
        var fds = [_]p.pollfd{
            .{ .fd = g.link.socket.fd, .events = p.POLL.IN, .revents = 0 },
            .{ .fd = if (g.eof or (!can_read and g.native.data().len == 0)) -1 else fd.*, .events = (if (can_read) @as(i16, p.POLL.IN) else 0) | (if (g.native.data().len > 0) @as(i16, p.POLL.OUT) else 0), .revents = 0 },
            .{ .fd = core.signal.sig_pipe[0], .events = p.POLL.IN, .revents = 0 },
        };
        _ = try p.poll(&fds, 20);
        if (fds[2].revents != 0) core.signal.drainSignalPipe();
        if (runtime.stopped.load(.acquire)) return error.GatewayInterrupted;
        // POLLHUP may accompany readable final data. Only read() == 0 ends
        // the stream, and a partially received final frame is always failure.
        if (can_read and fds[1].revents & (p.POLL.IN | p.POLL.HUP) != 0) try g.readNative(fd.*);
        if (!g.eof) try g.writeNative(fd.*, udp.nanoNow(io));
        if (fds[1].revents & (p.POLL.ERR | p.POLL.NVAL) != 0 and !g.eof) return error.NativeSocketFailure;
    }
}

fn notifyFailure(link: *link_mod.Link, io: std.Io, reason: []const u8) void {
    if (link.peer.addr == null) return;
    const start = udp.nanoNow(io);
    var queued = false;
    while (udp.nanoNow(io) - start < link_mod.drain_timeout_ns) {
        const now = udp.nanoNow(io);
        link.receive(now) catch return;
        if (!queued and link.outgoing.room() >= wire.header_len + reason.len) {
            link.enqueue(.SessionEnd, reason) catch return;
            queued = true;
        }
        link.tick(now) catch return;
        if (queued and link.idle()) return;
        var fds = [_]p.pollfd{.{ .fd = link.socket.fd, .events = p.POLL.IN, .revents = 0 }};
        _ = p.poll(&fds, 20) catch return;
    }
}

test "gateway forwards cap-sized snapshot incrementally without dropping final bytes" {
    const alloc = std.testing.allocator;
    var link = try link_mod.Link.init(alloc, try udp.UdpSocket.bindClient(udp.Address.initIp4(.{ 127, 0, 0, 1 }, 60000)), .{0} ** crypto.key_length, .to_client, 0);
    defer link.deinit();
    var g = Gateway{ .alloc = alloc, .link = &link, .native_progress = 0, .phase = .streaming };
    defer g.deinit();
    const header = core.ipc.Header{ .tag = .Output, .len = wire.max_payload };
    try g.frame.append(alloc, std.mem.asBytes(&header));
    const payload = try alloc.alloc(u8, wire.max_payload);
    defer alloc.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @truncate(i);
    try g.frame.append(alloc, payload);
    try g.forwardFrame();
    try std.testing.expect(g.output_cursor > 0 and g.output_cursor < payload.len);
    try std.testing.expectEqual(payload.len + @sizeOf(core.ipc.Header), g.frame.bytes.items.len);
    var received: usize = 0;
    while (true) {
        while (link.outgoing.data().len > 0) {
            const data = link.outgoing.data();
            const len = wire.header_len + @as(usize, std.mem.readInt(u32, data[1..5], .little));
            const msg = try wire.decode(data[0..len]);
            try std.testing.expectEqual(wire.Tag.Output, msg.tag);
            try std.testing.expectEqualSlices(u8, payload[received..][0..msg.data.len], msg.data);
            received += msg.data.len;
            link.outgoing.consume(len);
        }
        if (g.frame.bytes.items.len == 0) break;
        try g.forwardFrame();
    }
    try std.testing.expectEqual(payload.len, received);
}

test "gateway bounded native admission and deferred size handoff" {
    const alloc = std.testing.allocator;
    var link = try link_mod.Link.init(alloc, try udp.UdpSocket.bindClient(udp.Address.initIp4(.{ 127, 0, 0, 1 }, 60000)), .{0} ** crypto.key_length, .to_client, 0);
    defer link.deinit();
    var g = Gateway{ .alloc = alloc, .link = &link, .native_progress = 0, .phase = .streaming };
    defer g.deinit();
    const header = core.ipc.Header{ .tag = .Resize, .len = 0 };
    try g.frame.append(alloc, std.mem.asBytes(&header));
    try g.forwardFrame();
    try g.receiveRemote(0);
    try std.testing.expect(g.resize_requested);
    try std.testing.expectEqual(@as(usize, 0), g.native.data().len);
    const size = wire.encodeSize(.{ .rows = 31, .cols = 97 });
    try std.testing.expect(try g.appendRemote(.{ .tag = .Init, .data = &size }));
    try g.receiveRemote(0);
    try std.testing.expect(!g.resize_requested);
    const first_len = 28; // Native + legacy size messages.
    const resize = std.mem.bytesToValue(core.ipc.Header, g.native.data()[first_len..][0..8]);
    try std.testing.expectEqual(core.ipc.Tag.Resize, resize.tag);
    const room = g.native.room();
    const filler = try alloc.alloc(u8, room);
    defer alloc.free(filler);
    @memset(filler, 0);
    try g.native.append(alloc, filler);
    try std.testing.expect(!try g.appendRemote(.{ .tag = .Input, .data = "retained remotely" }));
    try std.testing.expectEqual(@as(usize, link_mod.limit), g.native.data().len);
}

test "gateway read pause uses hysteresis and a fixed two second deadline" {
    const alloc = std.testing.allocator;
    var link = try link_mod.Link.init(alloc, try udp.UdpSocket.bindClient(udp.Address.initIp4(.{ 127, 0, 0, 1 }, 60000)), .{0} ** crypto.key_length, .to_client, 0);
    defer link.deinit();
    var g = Gateway{ .alloc = alloc, .link = &link, .native_progress = 0, .phase = .streaming };
    defer g.deinit();
    const payload = try alloc.alloc(u8, pause_high);
    defer alloc.free(payload);
    @memset(payload, 0);
    try link.outgoing.append(alloc, payload);
    try std.testing.expect(try g.readPaused(100));
    try std.testing.expect(try g.readPaused(100 + pause_timeout - 1));
    try std.testing.expectError(error.NativeReadPauseTimeout, g.readPaused(100 + pause_timeout));
    link.outgoing.consume(pause_high - pause_low + 1);
    try std.testing.expect(!try g.readPaused(100 + pause_timeout));
}

test "gateway drains final readable frame before EOF and rejects partial final frame" {
    const alloc = std.testing.allocator;
    var link = try link_mod.Link.init(alloc, try udp.UdpSocket.bindClient(udp.Address.initIp4(.{ 127, 0, 0, 1 }, 60000)), .{0} ** crypto.key_length, .to_client, 0);
    defer link.deinit();
    for ([_]bool{ false, true }) |partial| {
        var g = Gateway{ .alloc = alloc, .link = &link, .native_progress = 0, .phase = .streaming };
        defer g.deinit();
        const pipe = try p.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        defer p.close(pipe[0]);
        const header = core.ipc.Header{ .tag = .Output, .len = 5 };
        _ = try p.write(pipe[1], std.mem.asBytes(&header));
        _ = try p.write(pipe[1], "final");
        if (partial) _ = try p.write(pipe[1], std.mem.asBytes(&header)[0..3]);
        p.close(pipe[1]);
        if (partial) {
            try std.testing.expectError(error.TruncatedNativeFrame, g.readNative(pipe[0]));
            try std.testing.expect(!g.eof);
        } else {
            try g.readNative(pipe[0]);
            try std.testing.expect(g.eof);
        }
        const msg = try wire.decode(link.outgoing.data());
        try std.testing.expectEqual(wire.Tag.Output, msg.tag);
        try std.testing.expectEqualStrings("final", msg.data);
        link.outgoing.consume(link.outgoing.data().len);
    }
}

test "gateway primes only first Init and retains later input behind processing barrier" {
    const alloc = std.testing.allocator;
    var link = try link_mod.Link.init(alloc, try udp.UdpSocket.bindClient(udp.Address.initIp4(.{ 127, 0, 0, 1 }, 60000)), .{0} ** crypto.key_length, .to_client, 0);
    defer link.deinit();
    var g = Gateway{ .alloc = alloc, .link = &link, .native_progress = 0 };
    defer g.deinit();
    const size = wire.encodeSize(.{ .rows = 24, .cols = 80 });
    var record: [128]u8 = undefined;
    _ = try link.recv.accept(1, try wire.encode(.Init, &size, &record));
    _ = try link.recv.accept(2, try wire.encode(.Input, "one command", &record));
    try g.receiveRemote(100);
    try std.testing.expectEqual(Gateway.Phase.priming, g.phase);
    try std.testing.expectEqual(@as(i64, 100), g.prime_started);
    try std.testing.expectEqual(wire.Tag.Input, (try wire.decode(link.recv.peek().?)).tag);
    try std.testing.expectEqual(@as(usize, 36), g.native.data().len); // Two Init sizes and Detach.
    const detach = std.mem.bytesToValue(core.ipc.Header, g.native.data()[28..36]);
    try std.testing.expectEqual(core.ipc.Tag.Detach, detach.tag);
    try g.receiveRemote(200);
    try std.testing.expectEqual(@as(usize, 36), g.native.data().len);
    try std.testing.expect(!g.detached);
    // A truncated provisional snapshot is intentionally discarded, never
    // acknowledged as terminal output or reported as successful termination.
    const pipe = try p.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    defer p.close(pipe[0]);
    _ = try p.write(pipe[1], "partial snapshot");
    p.close(pipe[1]);
    try g.readNative(pipe[0]);
    try std.testing.expect(g.eof);
    try std.testing.expectEqual(@as(usize, 0), link.outgoing.data().len);
    try std.testing.expectEqual(@as(usize, 0), g.frame.bytes.items.len);
}
