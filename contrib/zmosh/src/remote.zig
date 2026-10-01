// Adapted from mmonad/zmosh, revision 71eba23416bfb443df755ad89d6d06e665ebcd95.
// MIT license; see ../LICENSE and ../UPSTREAM.md.
const std = @import("std");
const zmx = @import("libzmx");
const p = zmx.posix;
const c = zmx.cross.c;
const bootstrap = @import("bootstrap.zig");
const udp = @import("udp.zig");
const link_mod = @import("link.zig");
const wire = @import("wire.zig");
const runtime = @import("runtime.zig");

pub fn run(alloc: std.mem.Allocator, io: std.Io, session: bootstrap.RemoteSession) !void {
    var failure: RemoteFailure = .{};
    // Report after terminal cleanup so its reset cannot erase the diagnostic.
    defer if (failure.len > 0) failure.report(2);
    const address = try udp.Address.resolve(session.host, session.port);
    var link = try link_mod.Link.init(alloc, try udp.UdpSocket.bindClient(address), session.key, .to_server, udp.nanoNow(io));
    defer link.deinit();
    link.peer.addr = address;
    try runtime.init();
    defer runtime.deinit();

    const stdin_flags = try runtime.nonblocking(0);
    defer _ = p.fcntl(0, p.F.SETFL, stdin_flags) catch 0;
    const stdout_flags = try runtime.nonblocking(1);
    defer _ = p.fcntl(1, p.F.SETFL, stdout_flags) catch 0;
    var original: c.termios = undefined;
    const tty = c.tcgetattr(0, &original) == 0;
    if (tty) {
        var raw = original;
        c.cfmakeraw(&raw);
        if (c.tcsetattr(0, c.TCSANOW, &raw) != 0) return error.TerminalSetupFailed;
    }
    defer if (tty) {
        _ = c.tcsetattr(0, c.TCSAFLUSH, &original);
        // Match local zmx's cleanup of terminal modes after detach/error.
        _ = p.write(1, "\x1bc\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\") catch 0;
    };
    var output: link_mod.Queue = .{};
    defer output.deinit(alloc);
    if (tty) try output.append(alloc, "\x1b[2J\x1b[H");
    const initial_size = wire.encodeSize(zmx.ipc.getTerminalSize(0));
    try link.enqueue(.Init, &initial_size);
    var last_stdout = udp.nanoNow(io);
    var detach_at: ?i64 = null;
    var ended_at: ?i64 = null;
    var input_closed = false;
    var detach_key: DetachKey = .{};
    const detach_enabled = p.getenv("ZMX_NO_DETACH_KEY") == null;

    while (true) {
        const now = udp.nanoNow(io);
        if (runtime.stopped.load(.acquire) and detach_at == null and ended_at == null) {
            try link.enqueue(.Detach, "");
            detach_at = now;
        }
        if (runtime.resized.swap(false, .acq_rel) and detach_at == null and ended_at == null) {
            const size = wire.encodeSize(zmx.ipc.getTerminalSize(0));
            try link.enqueue(.Resize, &size);
        }

        // Ordered records remain in their receive slots until the stdout sink
        // has retained capacity. ACK never requires an unbounded allocation.
        while (link.recv.peek()) |payload| {
            const msg = try wire.decode(payload);
            switch (msg.tag) {
                .Output => {
                    if (ended_at != null) return error.OutputAfterSessionEnd;
                    if (msg.data.len > output.room()) break;
                    if (output.data().len == 0) last_stdout = now;
                    try output.append(alloc, msg.data);
                },
                .SessionEnd => {
                    ended_at = now;
                    failure.set(msg.data);
                },
                else => return error.UnexpectedMessage,
            }
            link.recv.pop();
        }
        try tickLink(&link, now, ended_at);

        if (output.data().len > 0 and now - last_stdout >= link_mod.progress_timeout_ns) return error.StdoutTimeout;
        if (ended_at) |at| {
            if (output.data().len == 0) {
                // Keep ACKing duplicate terminal records briefly if the first
                // ACK is lost; stdout has already drained completely.
                if (now - at >= 250 * std.time.ns_per_ms) {
                    if (failure.len > 0) return error.RemoteSessionFailed;
                    return;
                }
            } else if (now - at >= link_mod.drain_timeout_ns) return error.IncompleteOutput;
        }
        if (detach_at) |at| {
            if (ended_at == null and now - at >= link_mod.drain_timeout_ns) return error.DetachTimeout;
        }

        if (detach_at == null and ended_at == null and detach_key.expired(now) and link.outgoing.room() >= wire.header_len + DetachKey.max_prefix) {
            var pending: [DetachKey.max_prefix]u8 = undefined;
            try link.enqueue(.Input, detach_key.flush(&pending));
        }

        var fds = [_]p.pollfd{
            .{ .fd = link.socket.fd, .events = p.POLL.IN, .revents = 0 },
            .{ .fd = if (!input_closed and detach_at == null and ended_at == null and link.outgoing.room() >= 4096) 0 else -1, .events = p.POLL.IN, .revents = 0 },
            .{ .fd = if (output.data().len > 0) 1 else -1, .events = p.POLL.OUT, .revents = 0 },
            .{ .fd = zmx.signal.sig_pipe[0], .events = p.POLL.IN, .revents = 0 },
        };
        _ = try p.poll(&fds, 20);
        if (fds[3].revents != 0) zmx.signal.drainSignalPipe();
        if (fds[0].revents & p.POLL.IN != 0) try link.receive(udp.nanoNow(io));
        if (fds[2].revents & (p.POLL.HUP | p.POLL.ERR | p.POLL.NVAL) != 0) return error.StdoutClosed;
        if (fds[2].revents & p.POLL.OUT != 0) {
            const n = p.write(1, output.data()) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n > 0) {
                output.consume(n);
                last_stdout = udp.nanoNow(io);
            }
        }
        if (fds[1].revents & (p.POLL.IN | p.POLL.HUP) != 0) {
            // Leave room to flush a prefix retained from the previous read.
            var buf: [link_mod.chunk_size - DetachKey.max_prefix]u8 = undefined;
            const n = p.read(0, &buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            var filtered: [link_mod.chunk_size]u8 = undefined;
            if (n == 0) {
                input_closed = true;
                const pending = detach_key.flush(&filtered);
                if (pending.len > 0) try link.enqueue(.Input, pending);
                try link.enqueue(.Detach, "");
                detach_at = now;
            } else {
                const result = detach_key.feed(buf[0..n], &filtered, detach_enabled, now);
                if (result.input.len > 0) try link.enqueue(.Input, result.input);
                if (result.detach) {
                    try link.enqueue(.Detach, "");
                    detach_at = now;
                }
            }
        }
    }
}

/// Retain only a possible supported Kitty detach prefix between stdin reads.
/// A lone Escape is released after a short idle interval rather than swallowed.
const DetachKey = struct {
    const sequences = [_][]const u8{ "\x1b[92;5u", "\x1b[92;5:1u" };
    const max_prefix = sequences[1].len;
    const timeout_ns = 100 * std.time.ns_per_ms;
    pending: [max_prefix]u8 = undefined,
    len: usize = 0,
    last_byte: i64 = 0,
    const Result = struct { input: []const u8, detach: bool };

    fn flush(self: *DetachKey, out: []u8) []const u8 {
        @memcpy(out[0..self.len], self.pending[0..self.len]);
        const len = self.len;
        self.len = 0;
        return out[0..len];
    }

    fn expired(self: *const DetachKey, now: i64) bool {
        return self.len > 0 and now - self.last_byte >= timeout_ns;
    }

    fn feed(self: *DetachKey, data: []const u8, out: []u8, enabled: bool, now: i64) Result {
        std.debug.assert(out.len >= data.len + self.len);
        var used: usize = 0;
        if (!enabled) {
            used = self.flush(out).len;
            @memcpy(out[used..][0..data.len], data);
            return .{ .input = out[0 .. used + data.len], .detach = false };
        }
        for (data) |byte| {
            if (byte == 0x1c) {
                used += self.flush(out[used..]).len;
                return .{ .input = out[0..used], .detach = true };
            }
            self.pending[self.len] = byte;
            self.len += 1;
            while (self.len > 0) {
                var is_prefix = false;
                for (sequences) |sequence| {
                    if (std.mem.eql(u8, self.pending[0..self.len], sequence)) {
                        self.len = 0;
                        return .{ .input = out[0..used], .detach = true };
                    }
                    if (std.mem.startsWith(u8, sequence, self.pending[0..self.len])) is_prefix = true;
                }
                if (is_prefix) break;
                out[used] = self.pending[0];
                used += 1;
                self.len -= 1;
                std.mem.copyForwards(u8, self.pending[0..self.len], self.pending[1..][0..self.len]);
            }
        }
        self.last_byte = now;
        return .{ .input = out[0..used], .detach = false };
    }
};

const RemoteFailure = struct {
    bytes: [96]u8 = undefined,
    len: usize = 0,

    fn set(self: *RemoteFailure, reason: []const u8) void {
        self.len = @min(reason.len, self.bytes.len);
        for (reason[0..self.len], self.bytes[0..self.len]) |byte, *dest| {
            dest.* = if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') byte else '?';
        }
    }

    fn report(self: *const RemoteFailure, fd: p.fd_t) void {
        const flags = p.fcntl(fd, p.F.GETFL, 0) catch return;
        _ = p.fcntl(fd, p.F.SETFL, flags | p.O_NONBLOCK) catch return;
        defer _ = p.fcntl(fd, p.F.SETFL, flags) catch 0;
        var buf: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "zmosh: remote failure: {s}\n", .{self.bytes[0..self.len]}) catch return;
        _ = p.write(fd, message) catch 0;
    }
};

test "detach matcher recognizes every split and preserves preceding bytes" {
    for (DetachKey.sequences) |sequence| {
        for (0..sequence.len + 1) |split| {
            var matcher: DetachKey = .{};
            var buf: [128]u8 = undefined;
            const prefix = matcher.feed("abc", &buf, true, 0);
            try std.testing.expectEqualStrings("abc", prefix.input);
            const first = matcher.feed(sequence[0..split], &buf, true, 0);
            try std.testing.expectEqualStrings("", first.input);
            if (split == sequence.len) {
                try std.testing.expect(first.detach);
            } else {
                try std.testing.expect(!first.detach);
                const second = matcher.feed(sequence[split..], &buf, true, 1);
                try std.testing.expect(second.detach);
                try std.testing.expectEqualStrings("", second.input);
            }
        }
    }
    for (DetachKey.sequences) |sequence| {
        var bytewise: DetachKey = .{};
        var output: [128]u8 = undefined;
        for (sequence, 0..) |byte, i| {
            const result = bytewise.feed(&.{byte}, &output, true, @intCast(i));
            try std.testing.expectEqual(i == sequence.len - 1, result.detach);
            try std.testing.expectEqualStrings("", result.input);
        }
    }
    var matcher: DetachKey = .{};
    var buf: [128]u8 = undefined;
    const preceding = matcher.feed("abc\x1cdiscard", &buf, true, 0);
    try std.testing.expect(preceding.detach);
    try std.testing.expectEqualStrings("abc", preceding.input);
    _ = matcher.feed("\x1b[92;", &buf, true, 0);
    const raw = matcher.feed("\x1cdiscard", &buf, true, 1);
    try std.testing.expect(raw.detach);
    try std.testing.expectEqualStrings("\x1b[92;", raw.input);
}

test "detach matcher flushes mismatches and disabled sequences in exact order" {
    const inputs = [_][]const u8{ "normal input", "\x1b[A", "\x1b[92;5:3u", "\x1b[92;6u", "\x1b\x1b[A" };
    for (inputs) |input| {
        for (0..input.len + 1) |split| {
            var matcher: DetachKey = .{};
            var buf: [128]u8 = undefined;
            var collected: [128]u8 = undefined;
            const first = matcher.feed(input[0..split], &buf, true, 0);
            try std.testing.expect(!first.detach);
            @memcpy(collected[0..first.input.len], first.input);
            const used = first.input.len;
            const second = matcher.feed(input[split..], &buf, true, 1);
            try std.testing.expect(!second.detach);
            @memcpy(collected[used..][0..second.input.len], second.input);
            try std.testing.expectEqualStrings(input, collected[0 .. used + second.input.len]);
        }
    }
    var matcher: DetachKey = .{};
    var buf: [128]u8 = undefined;
    const disabled = matcher.feed("abc\x1c\x1b[92;5u", &buf, false, 0);
    try std.testing.expect(!disabled.detach);
    try std.testing.expectEqualStrings("abc\x1c\x1b[92;5u", disabled.input);
}

test "detach prefix idle deadline and EOF flush preserve Escape" {
    var matcher: DetachKey = .{};
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", matcher.feed("\x1b", &buf, true, 10).input);
    try std.testing.expect(!matcher.expired(10 + DetachKey.timeout_ns - 1));
    try std.testing.expect(matcher.expired(10 + DetachKey.timeout_ns));
    try std.testing.expectEqualStrings("\x1b", matcher.flush(&buf));
    try std.testing.expect(!matcher.expired(10 + DetachKey.timeout_ns));
    _ = matcher.feed("\x1b[92;", &buf, true, 20);
    try std.testing.expectEqualStrings("\x1b[92;", matcher.flush(&buf));
}

test "remote failure reason is bounded and terminal safe" {
    var failure: RemoteFailure = .{};
    failure.set("NativeReadPauseTimeout");
    try std.testing.expectEqualStrings("NativeReadPauseTimeout", failure.bytes[0..failure.len]);
    failure.set("bad\x1b[2J\n\r\x00\xff");
    try std.testing.expectEqualStrings("bad??2J????", failure.bytes[0..failure.len]);
    failure.set(&(.{'x'} ** 200));
    try std.testing.expectEqual(@as(usize, 96), failure.len);
}

test "remote failure diagnostic never blocks on full pipe and restores flags" {
    const pipe = try p.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    defer p.close(pipe[0]);
    defer p.close(pipe[1]);
    const chunk = [_]u8{'x'} ** 4096;
    while (true) {
        _ = p.write(pipe[1], &chunk) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }
    const flags = try p.fcntl(pipe[1], p.F.GETFL, 0);
    const blocking = flags & ~p.O_NONBLOCK;
    _ = try p.fcntl(pipe[1], p.F.SETFL, blocking);
    var failure: RemoteFailure = .{};
    failure.set("NativeReadPauseTimeout");
    failure.report(pipe[1]);
    try std.testing.expectEqual(blocking, try p.fcntl(pipe[1], p.F.GETFL, 0));
}

fn tickLink(link: *link_mod.Link, now: i64, ended_at: ?i64) !void {
    // Repeat retention ACKs during the existing terminal grace: the first
    // ACK may be lost before the gateway's retransmission timer fires.
    if (ended_at != null) link.ack_dirty = true;
    try link.tick(now);
}

test "terminal ACK repeats within exit grace after first ACK is lost" {
    const crypto = @import("crypto.zig");
    const transport = @import("transport.zig");
    const key = [_]u8{0x42} ** crypto.key_length;
    var sink = try udp.UdpSocket.bind(61170, 61180);
    defer sink.close();
    const address = udp.Address.initIp4(.{ 127, 0, 0, 1 }, sink.bound_port);
    var link = try link_mod.Link.init(std.testing.allocator, try udp.UdpSocket.bindClient(address), key, .to_server, 0);
    defer link.deinit();
    link.peer.addr = address;
    var record: [wire.header_len]u8 = undefined;
    _ = try link.recv.accept(1, try wire.encode(.SessionEnd, "", &record));
    link.recv.pop();
    link.ack_dirty = true;
    try tickLink(&link, 20 * std.time.ns_per_ms, 0);
    var raw: [1500]u8 = undefined;
    _ = try sink.recvFrom(&raw); // Drop the first terminal ACK.
    try tickLink(&link, 40 * std.time.ns_per_ms, 0);
    const repeated = try sink.recvFrom(&raw);
    var plain: [1500]u8 = undefined;
    const decoded = try crypto.decodeDatagram(key, .to_server, raw[0..repeated.len], &plain);
    const packet = try transport.parsePacket(decoded.plaintext);
    try std.testing.expectEqual(transport.Channel.heartbeat, packet.channel);
    try std.testing.expectEqual(@as(u32, 1), packet.ack);
    try std.testing.expect(link.idle());
}
