//! Shared bounded scheduling for the fork-derived encrypted UDP transport.
const std = @import("std");
const udp = @import("udp.zig");
const crypto = @import("crypto.zig");
const transport = @import("transport.zig");
const wire = @import("wire.zig");

pub const limit = 1024 * 1024;
pub const progress_timeout_ns = 10 * std.time.ns_per_s;
pub const drain_timeout_ns = 5 * std.time.ns_per_s;
pub const chunk_size = transport.max_payload_len - wire.header_len;

pub const Queue = struct {
    bytes: std.ArrayList(u8) = .empty,
    head: usize = 0,

    pub fn deinit(self: *Queue, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
    }
    pub fn data(self: *const Queue) []const u8 {
        return self.bytes.items[self.head..];
    }
    pub fn room(self: *const Queue) usize {
        return limit - self.data().len;
    }
    pub fn append(self: *Queue, alloc: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len > self.room()) return error.QueueFull;
        if (self.head > 0 and self.bytes.items.len + bytes.len > limit) {
            const len = self.data().len;
            std.mem.copyForwards(u8, self.bytes.items[0..len], self.data());
            self.bytes.items.len = len;
            self.head = 0;
        }
        try self.bytes.appendSlice(alloc, bytes);
    }
    pub fn consume(self: *Queue, n: usize) void {
        std.debug.assert(n <= self.data().len);
        self.head += n;
        if (self.head == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.head = 0;
        }
    }
};

pub const Link = struct {
    alloc: std.mem.Allocator,
    socket: udp.UdpSocket,
    peer: udp.Peer,
    send: transport.ReliableSend,
    recv: transport.OrderedRecv = .{},
    outgoing: Queue = .{},
    last_ack: i64,
    last_progress: i64,
    ack_dirty: bool = false,

    pub fn init(alloc: std.mem.Allocator, socket: udp.UdpSocket, key: crypto.Key, direction: crypto.Direction, now: i64) !Link {
        return .{ .alloc = alloc, .socket = socket, .peer = udp.Peer.init(key, direction, now), .send = try transport.ReliableSend.init(alloc), .last_ack = now, .last_progress = now };
    }
    pub fn deinit(self: *Link) void {
        self.socket.close();
        self.send.deinit();
        self.outgoing.deinit(self.alloc);
    }
    pub fn idle(self: *const Link) bool {
        return !self.send.hasPending() and self.outgoing.data().len == 0;
    }
    pub fn enqueue(self: *Link, tag: wire.Tag, data: []const u8) !void {
        var buf: [transport.max_payload_len]u8 = undefined;
        const bytes = try wire.encode(tag, data, &buf);
        try self.outgoing.append(self.alloc, bytes);
    }
    fn transmit(self: *Link, bytes: []const u8, now: i64) !void {
        self.peer.send(&self.socket, bytes, now) catch |err| switch (err) {
            error.WouldBlock, error.NoPeerAddress, error.Interrupted, error.NetworkUnavailable => {},
            else => return err,
        };
    }
    pub fn tick(self: *Link, now: i64) !void {
        if (self.peer.updateState(now, .{ .alive_timeout_ms = 15_000 }) == .dead) return error.PeerTimeout;
        if (self.send.hasPending()) {
            if (now - self.last_progress >= progress_timeout_ns) return error.DeliveryTimeout;
        } else self.last_progress = now;
        if (self.peer.addr == null) return;
        if (!self.send.canSend() and !self.send.hasPending() and self.outgoing.data().len > 0) return error.SequenceExhausted;

        var retry = try self.send.collectRetransmits(self.alloc, now, self.peer.rto_us());
        defer retry.deinit(self.alloc);
        for (retry.items) |packet| try self.transmit(packet, now);
        while (self.send.canSend() and self.outgoing.data().len > 0) {
            const data = self.outgoing.data();
            const len = wire.header_len + @as(usize, std.mem.readInt(u32, data[1..5], .little));
            const packet = try self.send.buildAndTrack(.reliable_ipc, data[0..len], self.recv.ack(), self.recv.ackBits(), now);
            try self.transmit(packet, now);
            self.outgoing.consume(len);
        }
        if ((self.ack_dirty and now - self.last_ack >= 20 * std.time.ns_per_ms) or now - self.last_ack >= std.time.ns_per_s) {
            var buf: [transport.max_payload_len]u8 = undefined;
            const packet = try transport.buildUnreliable(.heartbeat, 0, self.recv.ack(), self.recv.ackBits(), "", &buf);
            try self.transmit(packet, now);
            self.last_ack = now;
            self.ack_dirty = false;
        }
    }
    pub fn receive(self: *Link, now: i64) !void {
        // Bound one poll iteration even under continuous hostile traffic.
        for (0..64) |_| {
            var buf: [9000]u8 = undefined;
            const received = (try self.peer.recv(&self.socket, &buf, now)) orelse break;
            const packet = transport.parsePacket(received.data) catch continue;
            if (packet.channel != .heartbeat and packet.channel != .reliable_ipc) continue;
            const before = self.send.oldestSeq();
            self.send.ack(packet.ack, packet.ack_bits);
            if (before != self.send.oldestSeq()) self.last_progress = now;
            if (packet.channel == .reliable_ipc) {
                _ = try wire.decode(packet.payload);
                _ = try self.recv.accept(packet.seq, packet.payload);
                self.ack_dirty = true;
            }
        }
    }
};

test "queue retains exact bytes across partial sink writes and compaction" {
    var q: Queue = .{};
    defer q.deinit(std.testing.allocator);
    const large = try std.testing.allocator.alloc(u8, limit);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');
    try q.append(std.testing.allocator, large);
    try std.testing.expectError(error.QueueFull, q.append(std.testing.allocator, "x"));
    q.consume(limit - 3);
    try q.append(std.testing.allocator, "bc");
    try std.testing.expectEqualStrings("aaabc", q.data());
    q.consume(5);
    try std.testing.expectEqual(@as(usize, limit), q.room());
}

test "authenticated liveness cannot extend a stalled reliable stream" {
    const address = udp.Address.initIp4(.{ 127, 0, 0, 1 }, 60000);
    var link = try Link.init(std.testing.allocator, try udp.UdpSocket.bindClient(address), .{0} ** crypto.key_length, .to_server, 0);
    defer link.deinit();
    _ = try link.send.buildAndTrack(.reliable_ipc, "retained", 0, 0, 0);
    link.peer.last_recv_time = progress_timeout_ns;
    try std.testing.expectError(error.DeliveryTimeout, link.tick(progress_timeout_ns));
}

test "exhausted reliable sequence fails instead of silently stalling queued data" {
    const address = udp.Address.initIp4(.{ 127, 0, 0, 1 }, 60000);
    var link = try Link.init(std.testing.allocator, try udp.UdpSocket.bindClient(address), .{0} ** crypto.key_length, .to_server, 0);
    defer link.deinit();
    link.peer.addr = address;
    link.send.next_seq = @as(u64, std.math.maxInt(u32)) + 1;
    try link.enqueue(.Input, "pending");
    try std.testing.expectError(error.SequenceExhausted, link.tick(0));
}

test "lost terminal packet retransmits with fresh nonce and retains ordered SessionEnd" {
    const alloc = std.testing.allocator;
    const key = [_]u8{0x31} ** crypto.key_length;
    var sink = try udp.UdpSocket.bind(61100, 61110);
    defer sink.close();
    const address = udp.Address.initIp4(.{ 127, 0, 0, 1 }, sink.bound_port);
    var link = try Link.init(alloc, try udp.UdpSocket.bindClient(address), key, .to_server, 0);
    defer link.deinit();
    link.peer.addr = address;
    try link.enqueue(.Output, "final bytes");
    try link.enqueue(.SessionEnd, "");
    try link.tick(0);
    var raw: [1500]u8 = undefined;
    var plain: [1500]u8 = undefined;
    var poll = [_]@import("zmx-core").posix.pollfd{.{ .fd = sink.fd, .events = @import("zmx-core").posix.POLL.IN, .revents = 0 }};
    _ = try @import("zmx-core").posix.poll(&poll, 1000);
    const output = try sink.recvFrom(&raw);
    const output_decoded = try crypto.decodeDatagram(key, .to_server, raw[0..output.len], &plain);
    try std.testing.expectEqual(wire.Tag.Output, (try wire.decode((try transport.parsePacket(output_decoded.plaintext)).payload)).tag);
    const first = try sink.recvFrom(&raw); // Simulate losing the terminal packet.
    const first_decoded = try crypto.decodeDatagram(key, .to_server, raw[0..first.len], &plain);
    const first_nonce = first_decoded.seq;
    const terminal_seq = (try transport.parsePacket(first_decoded.plaintext)).seq;
    try std.testing.expectEqual(wire.Tag.SessionEnd, (try wire.decode((try transport.parsePacket(first_decoded.plaintext)).payload)).tag);
    link.send.ack(1, 0); // Earlier Output retained; only terminal notification remains.
    try link.tick(std.time.ns_per_s - 1);
    try std.testing.expectError(error.WouldBlock, sink.recvFrom(&raw));
    try link.tick(std.time.ns_per_s);
    _ = try @import("zmx-core").posix.poll(&poll, 1000);
    const retry = try sink.recvFrom(&raw);
    const retry_decoded = try crypto.decodeDatagram(key, .to_server, raw[0..retry.len], &plain);
    try std.testing.expect(retry_decoded.seq > first_nonce);
    const packet = try transport.parsePacket(retry_decoded.plaintext);
    try std.testing.expectEqual(terminal_seq, packet.seq);
    try std.testing.expectEqual(wire.Tag.SessionEnd, (try wire.decode(packet.payload)).tag);
    try std.testing.expect(!link.idle());
    link.send.ack(terminal_seq, 0);
    try std.testing.expect(link.idle());
}

test "authenticated heartbeat traffic cannot extend oldest reliable progress deadline" {
    const alloc = std.testing.allocator;
    const key = [_]u8{0x32} ** crypto.key_length;
    var receiver = try Link.init(alloc, try udp.UdpSocket.bind(61110, 61120), key, .to_client, 0);
    defer receiver.deinit();
    const address = udp.Address.initIp4(.{ 127, 0, 0, 1 }, receiver.socket.bound_port);
    var source = try udp.UdpSocket.bindClient(address);
    defer source.close();
    var peer = udp.Peer.init(key, .to_server, 0);
    peer.addr = address;
    _ = try receiver.send.buildAndTrack(.reliable_ipc, "missing oldest", 0, 0, 0);
    _ = try receiver.send.buildAndTrack(.reliable_ipc, "later", 0, 0, 0);
    var buf: [128]u8 = undefined;
    const heartbeat = try transport.buildUnreliable(.heartbeat, 0, 2, 0, "", &buf);
    var poll = [_]@import("zmx-core").posix.pollfd{.{ .fd = receiver.socket.fd, .events = @import("zmx-core").posix.POLL.IN, .revents = 0 }};
    for (1..11) |second| {
        const now: i64 = @intCast(second * std.time.ns_per_s);
        try peer.send(&source, heartbeat, now);
        _ = try @import("zmx-core").posix.poll(&poll, 1000);
        try receiver.receive(now);
        try std.testing.expectEqual(now, receiver.peer.last_recv_time);
        try std.testing.expectEqual(@as(i64, 0), receiver.last_progress);
        try std.testing.expectEqual(@as(?u32, 1), receiver.send.oldestSeq());
    }
    try std.testing.expectError(error.DeliveryTimeout, receiver.tick(progress_timeout_ns));
}

test "losing all terminal packets eventually triggers independent dead peer deadline" {
    const address = udp.Address.initIp4(.{ 127, 0, 0, 1 }, 61130);
    var client = try Link.init(std.testing.allocator, try udp.UdpSocket.bindClient(address), .{0} ** crypto.key_length, .to_server, 0);
    defer client.deinit();
    // No terminal record was retained and no reliable client data is pending.
    // Last authenticated traffic remains the reference even when local ticks
    // continue throughout the gateway's five-second terminal drain interval.
    try client.tick(5 * std.time.ns_per_s);
    try client.tick(15 * std.time.ns_per_s - 1);
    try std.testing.expectError(error.PeerTimeout, client.tick(15 * std.time.ns_per_s));
    try std.testing.expect(client.recv.peek() == null);
}

test "unknown authenticated wire tag is rejected without receive admission" {
    const key = [_]u8{0x33} ** crypto.key_length;
    var receiver = try Link.init(std.testing.allocator, try udp.UdpSocket.bind(61130, 61140), key, .to_client, 0);
    defer receiver.deinit();
    const address = udp.Address.initIp4(.{ 127, 0, 0, 1 }, receiver.socket.bound_port);
    var source = try udp.UdpSocket.bindClient(address);
    defer source.close();
    var peer = udp.Peer.init(key, .to_server, 0);
    peer.addr = address;
    var message: [wire.header_len]u8 = .{0} ** wire.header_len;
    message[0] = 255;
    var buf: [128]u8 = undefined;
    try peer.send(&source, try transport.buildUnreliable(.reliable_ipc, 1, 0, 0, &message, &buf), 1);
    var poll = [_]@import("zmx-core").posix.pollfd{.{ .fd = receiver.socket.fd, .events = @import("zmx-core").posix.POLL.IN, .revents = 0 }};
    _ = try @import("zmx-core").posix.poll(&poll, 1000);
    try std.testing.expectError(error.UnknownTag, receiver.receive(1));
    try std.testing.expectEqual(@as(u32, 0), receiver.recv.ack());
    try std.testing.expect(receiver.recv.peek() == null);
}

test "isolated route outage retains reliable data and recovers with fresh nonce" {
    if (@import("zmx-core").posix.getenv("ZMOSH_TEST_NO_ROUTE") == null) return error.SkipZigTest;
    const key = [_]u8{0x55} ** crypto.key_length;
    const unavailable_address = udp.Address.initIp4(.{ 192, 0, 2, 1 }, 60000);
    var link = try Link.init(std.testing.allocator, try udp.UdpSocket.bindClient(unavailable_address), key, .to_server, 0);
    defer link.deinit();
    link.peer.addr = unavailable_address;
    // This fixture must run under Docker --network none: real ENETUNREACH,
    // not a packet-dropping proxy or a mocked send result.
    try std.testing.expectError(error.NetworkUnavailable, link.socket.sendTo("route probe", unavailable_address));
    try link.enqueue(.Input, "preserve across route outage");
    try link.tick(0);
    try std.testing.expect(link.send.hasPending());
    try std.testing.expectEqual(@as(u64, 1), link.peer.send_seq);
    try link.tick(std.time.ns_per_s);
    try std.testing.expect(link.send.hasPending());
    const reserved = link.peer.send_seq;
    try std.testing.expect(reserved >= 2);
    // Route becomes usable again, represented by a reachable loopback peer.
    var receiver = try udp.UdpSocket.bind(61210, 61220);
    defer receiver.close();
    link.peer.addr = udp.Address.initIp4(.{ 127, 0, 0, 1 }, receiver.bound_port);
    try link.tick(2 * std.time.ns_per_s);
    var raw: [1500]u8 = undefined;
    var plain: [1500]u8 = undefined;
    const packet = try receiver.recvFrom(&raw);
    const decoded = try crypto.decodeDatagram(key, .to_server, raw[0..packet.len], &plain);
    try std.testing.expect(decoded.seq >= reserved);
    const retained = try transport.parsePacket(decoded.plaintext);
    try std.testing.expectEqual(@as(u32, 1), retained.seq);
    try std.testing.expectEqualStrings("preserve across route outage", (try wire.decode(retained.payload)).data);
    // Recovery does not erase the existing reliable-progress deadline if no
    // ACK arrives; continued route failure remains bounded too.
    link.peer.addr = unavailable_address;
    try std.testing.expectError(error.DeliveryTimeout, link.tick(progress_timeout_ns));
}
