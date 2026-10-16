// Adapted from mmonad/zmosh, revision 71eba23416bfb443df755ad89d6d06e665ebcd95.
// MIT license; see ../LICENSE and ../UPSTREAM.md.
const std = @import("std");
const posix = @import("libzmx").posix;
const crypto = @import("crypto.zig");

const log = std.log.scoped(.udp);

/// Monotonic clock, independent of wall-clock adjustments.
pub fn nanoNow(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

pub const Config = struct {
    heartbeat_interval_ms: u32 = 1000,
    heartbeat_timeout_ms: u32 = 5000,
    alive_timeout_ms: u32 = 15_000,
    port_range_start: u16 = 60000,
    port_range_end: u16 = 61000,
};

pub const PeerState = enum {
    connected,
    disconnected,
    dead,
};

pub const UdpSocket = struct {
    fd: i32,
    bound_port: u16,

    /// Bind a non-blocking UDP socket to the first available port in [port_start, port_end).
    /// Uses AF.INET6 with dual-stack when possible, falling back to AF.INET.
    pub fn bind(port_start: u16, port_end: u16) !UdpSocket {
        if (port_start >= port_end) return error.AddressInUse;
        return bindFamily(posix.AF.INET6, port_start, port_end, true) catch |err| {
            try allowIp4Fallback(err);
            return bindFamily(posix.AF.INET, port_start, port_end, false);
        };
    }

    fn allowIp4Fallback(err: anyerror) !void {
        switch (err) {
            error.AddressInUse, error.AddressFamilyNotSupported, error.ProtocolFamilyNotAvailable, error.ProtocolNotSupported, error.DualStackUnsupported => {},
            else => return err,
        }
    }

    fn bindFamily(family: u32, port_start: u16, port_end: u16, set_v6only: bool) !UdpSocket {
        const fd = try posix.socket(
            family,
            posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);

        if (set_v6only) {
            const v6only: c_int = 0;
            const result = c.setsockopt(fd, c.IPPROTO_IPV6, c.IPV6_V6ONLY, &v6only, @sizeOf(c_int));
            if (result != 0) return socketOptionError(std.posix.errno(result));
        }

        var port = port_start;
        while (port < port_end) : (port += 1) {
            const addr = if (family == posix.AF.INET6)
                Address.initIp6(.{0} ** 16, port, 0, 0)
            else
                Address.initIp4(.{0} ** 4, port);
            posix.bind(fd, @ptrCast(&addr.any), addr.getOsSockLen()) catch |err| switch (err) {
                error.AddressInUse => continue,
                else => return err,
            };
            log.info("bound udp port={d} family={s}", .{
                port,
                if (family == posix.AF.INET6) "inet6" else "inet",
            });
            return .{ .fd = fd, .bound_port = port };
        }
        return error.AddressInUse;
    }

    fn socketOptionError(err: std.c.E) anyerror {
        return switch (err) {
            .NOPROTOOPT, .OPNOTSUPP => error.DualStackUnsupported,
            .ACCES, .PERM => error.AccessDenied,
            .NOBUFS, .NOMEM => error.SystemResources,
            .BADF => error.BadFileDescriptor,
            .NOTSOCK => error.FileDescriptorNotASocket,
            .INVAL => error.InvalidSocketOption,
            else => error.SocketOptionFailed,
        };
    }

    pub fn getFd(self: *const UdpSocket) i32 {
        return self.fd;
    }

    pub fn bindClient(addr: Address) !UdpSocket {
        const fd = try posix.socket(@intCast(addr.any.family), posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
        return .{ .fd = fd, .bound_port = 0 };
    }

    pub fn sendTo(self: *UdpSocket, data: []const u8, addr: Address) !void {
        const n = c.sendto(self.fd, data.ptr, data.len, 0, @ptrCast(&addr.any), addr.getOsSockLen());
        if (n < 0) return sendError(std.posix.errno(n));
        if (@as(usize, @intCast(n)) != data.len) return error.SendFailed;
    }

    fn sendError(err: std.c.E) anyerror {
        return switch (err) {
            .AGAIN => error.WouldBlock,
            .INTR => error.Interrupted,
            // Losing a route/interface is recoverable within the existing
            // authenticated liveness and reliable-progress deadlines.
            .NETUNREACH, .HOSTUNREACH, .NETDOWN => error.NetworkUnavailable,
            else => error.SendFailed,
        };
    }

    pub fn recvFrom(self: *UdpSocket, buf: []u8) !struct { len: usize, addr: Address } {
        var addr: Address = .{ .any = std.mem.zeroes(posix.sockaddr.storage) };
        var len: c.socklen_t = @sizeOf(Address);
        const n = c.recvfrom(self.fd, buf.ptr, buf.len, 0, @ptrCast(&addr.any), &len);
        if (n < 0) return switch (std.posix.errno(n)) {
            .AGAIN => error.WouldBlock,
            .INTR => error.Interrupted,
            else => error.ReceiveFailed,
        };
        return .{ .len = @intCast(n), .addr = addr };
    }

    pub fn close(self: *UdpSocket) void {
        posix.close(self.fd);
    }
};

pub const Peer = struct {
    addr: ?Address,
    key: crypto.Key,

    // Sequence numbers
    send_seq: u64,
    has_received: bool = false,
    max_recv_seq: u63,

    // RTT estimation (RFC 6298, 50ms min RTO like Mosh)
    srtt_us: ?i64,
    rttvar_us: ?i64,

    // Timestamps for RTT measurement
    last_send_time: ?i64,

    // Heartbeat tracking
    last_recv_time: i64,
    last_send_time_any: i64,

    // State
    state: PeerState,
    direction: crypto.Direction,

    pub fn init(key: crypto.Key, direction: crypto.Direction, now: i64) Peer {
        return .{
            .addr = null,
            .key = key,
            .send_seq = 0,
            .max_recv_seq = 0,
            .srtt_us = null,
            .rttvar_us = null,
            .last_send_time = null,
            .last_recv_time = now,
            .last_send_time_any = now,
            .state = .connected,
            .direction = direction,
        };
    }

    fn reserveSequence(self: *Peer) !u63 {
        if (self.send_seq > std.math.maxInt(u63)) return error.SequenceExhausted;
        const seq: u63 = @intCast(self.send_seq);
        self.send_seq += 1;
        return seq;
    }

    /// Send an encrypted datagram. Increments send_seq.
    pub fn send(self: *Peer, sock: *UdpSocket, plaintext: []const u8, now: i64) !void {
        const addr = self.addr orelse return error.NoPeerAddress;

        var buf: [9000]u8 = undefined;
        const datagram = try crypto.encodeDatagram(
            self.key,
            self.direction,
            try self.reserveSequence(),
            plaintext,
            &buf,
        );

        try sock.sendTo(datagram, addr);

        self.last_send_time = now;
        self.last_send_time_any = now;
    }

    /// Try to receive and decrypt a datagram. Updates peer address on success (roaming).
    /// Returns null if no data available (EAGAIN) or decryption fails.
    pub fn recv(self: *Peer, sock: *UdpSocket, buf: []u8, now: i64) !?struct { data: []u8, from: Address } {
        var raw: [9000]u8 = undefined;
        const result = sock.recvFrom(&raw) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };

        // Determine expected direction: if we send to_server, we receive to_client
        const recv_direction: crypto.Direction = switch (self.direction) {
            .to_server => .to_client,
            .to_client => .to_server,
        };

        const decoded = crypto.decodeDatagram(
            self.key,
            recv_direction,
            raw[0..result.len],
            buf,
        ) catch return null;

        // Anti-replay + roaming: only update state if seq > max_recv_seq.
        // Old or duplicate packets are dropped after authentication.
        if (!self.has_received or decoded.seq > self.max_recv_seq) {
            self.has_received = true;
            self.addr = result.addr;
            self.max_recv_seq = decoded.seq;
            self.last_recv_time = now;

            // RTT measurement
            if (self.last_send_time) |send_time| {
                const rtt_ns = now - send_time;
                if (rtt_ns > 0) {
                    self.updateRtt(@divFloor(rtt_ns, std.time.ns_per_us));
                }
                self.last_send_time = null;
            }
        } else {
            return null;
        }

        if (self.state == .disconnected) {
            self.state = .connected;
            log.info("peer reconnected", .{});
        }

        return .{ .data = decoded.plaintext, .from = result.addr };
    }

    /// Check if a heartbeat should be sent.
    pub fn shouldSendHeartbeat(self: *const Peer, now: i64, config: Config) bool {
        const interval_ns = @as(i64, config.heartbeat_interval_ms) * std.time.ns_per_ms;
        return (now - self.last_send_time_any) >= interval_ns;
    }

    /// Update peer state based on time since last recv.
    pub fn updateState(self: *Peer, now: i64, config: Config) PeerState {
        const since_recv_ns = now - self.last_recv_time;
        const alive_ns = @as(i64, config.alive_timeout_ms) * std.time.ns_per_ms;
        const hb_ns = @as(i64, config.heartbeat_timeout_ms) * std.time.ns_per_ms;

        if (since_recv_ns >= alive_ns) {
            self.state = .dead;
        } else if (since_recv_ns >= hb_ns) {
            if (self.state == .connected) {
                log.warn("peer disconnected (heartbeat timeout)", .{});
            }
            self.state = .disconnected;
        }

        return self.state;
    }

    /// Compute the retransmission timeout in microseconds.
    pub fn rto_us(self: *const Peer) i64 {
        const min_rto: i64 = 50_000; // 50ms
        if (self.srtt_us) |srtt| {
            const rttvar = self.rttvar_us orelse 0;
            return @max(min_rto, srtt + 4 * rttvar);
        }
        return 1_000_000; // 1s default
    }

    /// Update RTT estimate (RFC 6298, 50ms min RTO).
    fn updateRtt(self: *Peer, rtt_us: i64) void {
        if (self.srtt_us) |srtt| {
            const rttvar = self.rttvar_us orelse 0;
            const diff = if (srtt > rtt_us) srtt - rtt_us else rtt_us - srtt;
            self.rttvar_us = @divFloor(3 * rttvar, 4) + @divFloor(diff, 4);
            self.srtt_us = @divFloor(7 * srtt, 8) + @divFloor(rtt_us, 8);
        } else {
            self.srtt_us = rtt_us;
            self.rttvar_us = @divFloor(rtt_us, 2);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Bind a non-blocking IPv4-only UDP socket on loopback for testing.
fn testBindIp4(port_start: u16, port_end: u16) !UdpSocket {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    var port = port_start;
    while (port < port_end) : (port += 1) {
        const addr = Address.initIp4(.{ 127, 0, 0, 1 }, port);
        posix.bind(fd, @ptrCast(&addr.any), addr.getOsSockLen()) catch continue;
        return .{ .fd = fd, .bound_port = port };
    }
    return error.AddressInUse;
}

fn testPollReady(fd: i32) !void {
    var poll_fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    _ = try posix.poll(&poll_fds, 1000);
}

test "UdpSocket bind in port range" {
    var sock = try UdpSocket.bind(60900, 60910);
    defer sock.close();
    try std.testing.expect(sock.bound_port >= 60900);
    try std.testing.expect(sock.bound_port < 60910);
    try std.testing.expect(sock.fd >= 0);
}

test "UdpSocket bind fails on empty range" {
    const result = UdpSocket.bind(60000, 60000);
    try std.testing.expectError(error.AddressInUse, result);
}

test "Peer send/recv round-trip (loopback)" {
    const key = try crypto.generateKey(std.testing.io);
    var server_peer = Peer.init(key, .to_client, nanoNow(std.testing.io));

    var server_sock = try testBindIp4(60910, 60920);
    defer server_sock.close();
    var client_sock = try testBindIp4(60920, 60930);
    defer client_sock.close();

    const msg = "hello, server!";
    var enc_buf: [crypto.overhead + msg.len]u8 = undefined;
    const datagram = try crypto.encodeDatagram(key, .to_server, 0, msg, &enc_buf);
    try client_sock.sendTo(datagram, Address.initIp4(.{ 127, 0, 0, 1 }, server_sock.bound_port));

    try testPollReady(server_sock.fd);
    var peer_buf: [4096]u8 = undefined;
    const recv_result = try server_peer.recv(&server_sock, &peer_buf, nanoNow(std.testing.io));
    try std.testing.expect(recv_result != null);
    try std.testing.expectEqualStrings(msg, recv_result.?.data);
}

test "Anti-replay: reject datagram with seq <= max_recv_seq" {
    const key = try crypto.generateKey(std.testing.io);
    var peer = Peer.init(key, .to_client, nanoNow(std.testing.io));

    var sock_recv = try testBindIp4(60930, 60940);
    defer sock_recv.close();
    var sock_send = try testBindIp4(60940, 60950);
    defer sock_send.close();

    const target = Address.initIp4(.{ 127, 0, 0, 1 }, sock_recv.bound_port);

    var buf_lo: [128]u8 = undefined;
    const pkt_lo = try crypto.encodeDatagram(key, .to_server, 5, "first", &buf_lo);
    var buf_hi: [128]u8 = undefined;
    const pkt_hi = try crypto.encodeDatagram(key, .to_server, 10, "second", &buf_hi);

    // Send higher seq first
    try sock_send.sendTo(pkt_hi, target);
    try testPollReady(sock_recv.fd);

    var recv_buf: [4096]u8 = undefined;
    const r1 = try peer.recv(&sock_recv, &recv_buf, nanoNow(std.testing.io));
    try std.testing.expect(r1 != null);
    try std.testing.expect(peer.max_recv_seq == 10);

    // Send lower seq — packet is dropped.
    const old_port = peer.addr.?.getPort();
    try sock_send.sendTo(pkt_lo, target);
    try testPollReady(sock_recv.fd);

    var recv_buf2: [4096]u8 = undefined;
    const r2 = try peer.recv(&sock_recv, &recv_buf2, nanoNow(std.testing.io));
    try std.testing.expect(r2 == null);
    try std.testing.expect(peer.max_recv_seq == 10);
    try std.testing.expect(peer.addr.?.getPort() == old_port);
}

test "Roaming: verify addr updates on authentic packet" {
    const key = try crypto.generateKey(std.testing.io);
    var peer = Peer.init(key, .to_client, nanoNow(std.testing.io));

    var sock_recv = try testBindIp4(60950, 60960);
    defer sock_recv.close();
    var sock_a = try testBindIp4(60960, 60970);
    defer sock_a.close();
    var sock_b = try testBindIp4(60970, 60980);
    defer sock_b.close();

    const target = Address.initIp4(.{ 127, 0, 0, 1 }, sock_recv.bound_port);

    var buf1: [128]u8 = undefined;
    try sock_a.sendTo(try crypto.encodeDatagram(key, .to_server, 1, "from_a", &buf1), target);
    try testPollReady(sock_recv.fd);

    var rb1: [4096]u8 = undefined;
    _ = try peer.recv(&sock_recv, &rb1, nanoNow(std.testing.io));
    const port_a = peer.addr.?.getPort();

    var buf2: [128]u8 = undefined;
    try sock_b.sendTo(try crypto.encodeDatagram(key, .to_server, 2, "from_b", &buf2), target);
    try testPollReady(sock_recv.fd);

    var rb2: [4096]u8 = undefined;
    _ = try peer.recv(&sock_recv, &rb2, nanoNow(std.testing.io));
    const port_b = peer.addr.?.getPort();

    try std.testing.expect(port_a != port_b);
}

test "Heartbeat timing logic" {
    var peer = Peer.init(try crypto.generateKey(std.testing.io), .to_server, nanoNow(std.testing.io));
    const config = Config{};
    const now = nanoNow(std.testing.io);

    peer.last_send_time_any = now;
    try std.testing.expect(!peer.shouldSendHeartbeat(now, config));

    const later = now + @as(i64, config.heartbeat_interval_ms) * std.time.ns_per_ms + 1;
    try std.testing.expect(peer.shouldSendHeartbeat(later, config));
}

test "Peer state transitions" {
    var peer = Peer.init(try crypto.generateKey(std.testing.io), .to_server, nanoNow(std.testing.io));
    const config = Config{};
    const now = nanoNow(std.testing.io);
    peer.last_recv_time = now;

    try std.testing.expect(peer.updateState(now + 1000, config) == .connected);

    const after_hb = now + @as(i64, config.heartbeat_timeout_ms) * std.time.ns_per_ms + 1;
    try std.testing.expect(peer.updateState(after_hb, config) == .disconnected);

    peer.state = .connected;
    peer.last_recv_time = now;
    const after_alive = now + @as(i64, config.alive_timeout_ms) * std.time.ns_per_ms + 1;
    try std.testing.expect(peer.updateState(after_alive, config) == .dead);
}

test "RTT estimation basic sanity" {
    var peer = Peer.init(try crypto.generateKey(std.testing.io), .to_server, nanoNow(std.testing.io));

    // First measurement: 100ms
    peer.updateRtt(100_000);
    try std.testing.expect(peer.srtt_us.? == 100_000);
    try std.testing.expect(peer.rttvar_us.? == 50_000);
    try std.testing.expect(peer.rto_us() == 300_000);

    // Second measurement: 120ms
    peer.updateRtt(120_000);
    try std.testing.expect(peer.rttvar_us.? == 42_500);
    try std.testing.expect(peer.srtt_us.? == 102_500);

    // Third measurement: 50ms
    peer.updateRtt(50_000);
    try std.testing.expect(peer.rttvar_us.? == 45_000);
    try std.testing.expect(peer.srtt_us.? == 95_937);
}

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("netdb.h");
    @cInclude("sys/resource.h");
});

pub const Address = extern union {
    any: posix.sockaddr.storage,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,

    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        return .{ .in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(bytes) } };
    }

    pub fn initIp6(bytes: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        return .{ .in6 = .{ .port = std.mem.nativeToBig(u16, port), .addr = bytes, .flowinfo = flowinfo, .scope_id = scope_id } };
    }

    pub fn getPort(self: Address) u16 {
        return std.mem.bigToNative(u16, if (self.any.family == posix.AF.INET6) self.in6.port else self.in.port);
    }

    pub fn getOsSockLen(self: Address) posix.socklen_t {
        return if (self.any.family == posix.AF.INET6) @sizeOf(posix.sockaddr.in6) else @sizeOf(posix.sockaddr.in);
    }

    /// libc resolver accepts numeric addresses and ordinary DNS hostnames.
    pub fn resolve(host: []const u8, port: u16) !Address {
        if (host.len == 0 or host.len > 253 or std.mem.indexOfScalar(u8, host, 0) != null) return error.InvalidHost;
        var name: [254]u8 = undefined;
        @memcpy(name[0..host.len], host);
        name[host.len] = 0;
        var service: [6]u8 = undefined;
        const service_z = try std.fmt.bufPrintZ(&service, "{d}", .{port});
        var hints = std.mem.zeroes(c.struct_addrinfo);
        hints.ai_family = c.AF_UNSPEC;
        hints.ai_socktype = c.SOCK_DGRAM;
        var result: ?*c.struct_addrinfo = null;
        if (c.getaddrinfo(@ptrCast(&name), service_z.ptr, &hints, &result) != 0) return error.ResolveFailed;
        defer c.freeaddrinfo(result);
        var current = result;
        while (current) |entry| : (current = entry.ai_next) {
            if (entry.ai_family != c.AF_INET and entry.ai_family != c.AF_INET6) continue;
            var addr = Address{ .any = std.mem.zeroes(posix.sockaddr.storage) };
            if (entry.ai_addrlen > @sizeOf(Address)) continue;
            @memcpy(std.mem.asBytes(&addr)[0..entry.ai_addrlen], @as([*]const u8, @ptrCast(entry.ai_addr))[0..entry.ai_addrlen]);
            return addr;
        }
        return error.ResolveFailed;
    }
};

test "sequence zero replay cannot refresh liveness or roam" {
    const key = try crypto.generateKey(std.testing.io);
    var peer = Peer.init(key, .to_client, 100);
    var receiver = try testBindIp4(60980, 60990);
    defer receiver.close();
    var sender = try testBindIp4(60990, 61000);
    defer sender.close();
    var other = try testBindIp4(61000, 61010);
    defer other.close();
    const target = Address.initIp4(.{ 127, 0, 0, 1 }, receiver.bound_port);
    var packet: [128]u8 = undefined;
    const encrypted = try crypto.encodeDatagram(key, .to_server, 0, "zero", &packet);
    var plain: [128]u8 = undefined;
    try sender.sendTo(encrypted, target);
    try testPollReady(receiver.fd);
    try std.testing.expect((try peer.recv(&receiver, &plain, 200)) != null);
    try other.sendTo(encrypted, target);
    try testPollReady(receiver.fd);
    try std.testing.expect((try peer.recv(&receiver, &plain, 300)) == null);
    try std.testing.expectEqual(@as(i64, 200), peer.last_recv_time);
    try std.testing.expectEqual(sender.bound_port, peer.addr.?.getPort());
    packet[8] ^= 1;
    try other.sendTo(encrypted, target);
    try testPollReady(receiver.fd);
    try std.testing.expect((try peer.recv(&receiver, &plain, 400)) == null);
    try std.testing.expectEqual(@as(i64, 200), peer.last_recv_time);
    try std.testing.expectEqual(sender.bound_port, peer.addr.?.getPort());
}

test "failed send consumes nonce and sequence cannot exhaust into direction bit" {
    var peer = Peer.init(try crypto.generateKey(std.testing.io), .to_server, 0);
    peer.addr = Address.initIp4(.{ 127, 0, 0, 1 }, 60000);
    var invalid_socket = UdpSocket{ .fd = -1, .bound_port = 0 };
    try std.testing.expectError(error.SendFailed, peer.send(&invalid_socket, "failure", 100));
    try std.testing.expectEqual(@as(u64, 1), peer.send_seq);
    try std.testing.expectEqual(@as(i64, 0), peer.last_send_time_any);
    peer.send_seq = std.math.maxInt(u63);
    try std.testing.expectError(error.SendFailed, peer.send(&invalid_socket, "last", 200));
    try std.testing.expectError(error.SequenceExhausted, peer.send(&invalid_socket, "wrap", 300));
    peer.send_seq = std.math.maxInt(u64);
    try std.testing.expectError(error.SequenceExhausted, peer.send(&invalid_socket, "overflow", 400));
}

test "resolve numeric and local host addresses" {
    const addr = try Address.resolve("127.0.0.1", 12345);
    try std.testing.expectEqual(@as(u16, 12345), addr.getPort());
    _ = try Address.resolve("localhost", 12345);
    var client = try UdpSocket.bindClient(addr);
    defer client.close();
}

test "forged high sequence cannot poison replay state or roam authenticated peer" {
    const key = [_]u8{0x41} ** crypto.key_length;
    var peer = Peer.init(key, .to_client, 0);
    var receiver = try testBindIp4(61140, 61150);
    defer receiver.close();
    var source = try testBindIp4(61150, 61160);
    defer source.close();
    var forged_source = try testBindIp4(61160, 61170);
    defer forged_source.close();
    const target = Address.initIp4(.{ 127, 0, 0, 1 }, receiver.bound_port);
    var packet: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    try source.sendTo(try crypto.encodeDatagram(key, .to_server, 1, "authentic", &packet), target);
    try testPollReady(receiver.fd);
    _ = (try peer.recv(&receiver, &plain, 100)).?;
    const forged = try crypto.encodeDatagram(key, .to_server, 2, "forged prefix", &packet);
    std.mem.writeInt(u64, packet[0..8], std.math.maxInt(u63), .big);
    try forged_source.sendTo(forged, target);
    try testPollReady(receiver.fd);
    try std.testing.expect((try peer.recv(&receiver, &plain, 200)) == null);
    try std.testing.expectEqual(@as(u63, 1), peer.max_recv_seq);
    try std.testing.expectEqual(@as(i64, 100), peer.last_recv_time);
    try std.testing.expectEqual(source.bound_port, peer.addr.?.getPort());
    // The genuine next sequence remains admissible from a new source.
    try forged_source.sendTo(try crypto.encodeDatagram(key, .to_server, 2, "fresh roaming", &packet), target);
    try testPollReady(receiver.fd);
    try std.testing.expectEqualStrings("fresh roaming", (try peer.recv(&receiver, &plain, 300)).?.data);
    try std.testing.expectEqual(@as(u63, 2), peer.max_recv_seq);
    try std.testing.expectEqual(forged_source.bound_port, peer.addr.?.getPort());
}

test "socket descriptor exhaustion is reported without family fallback" {
    var original: c.struct_rlimit = undefined;
    if (c.getrlimit(c.RLIMIT_NOFILE, &original) != 0) return error.SkipZigTest;
    var reduced = original;
    reduced.rlim_cur = 0;
    if (c.setrlimit(c.RLIMIT_NOFILE, &reduced) != 0) return error.SkipZigTest;
    const result = UdpSocket.bind(61200, 61210);
    const restored = c.setrlimit(c.RLIMIT_NOFILE, &original);
    if (restored != 0) return error.RestoreDescriptorLimitFailed;
    try std.testing.expectError(error.ProcessFdQuotaExceeded, result);
}

test "socket fallback permits unsupported families but preserves hard setup failures" {
    for ([_]anyerror{ error.AddressInUse, error.AddressFamilyNotSupported, error.ProtocolFamilyNotAvailable, error.ProtocolNotSupported, error.DualStackUnsupported }) |err| {
        try UdpSocket.allowIp4Fallback(err);
    }
    for ([_]anyerror{ error.AccessDenied, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources, error.InvalidSocketOption, error.BadFileDescriptor }) |err| {
        try std.testing.expectError(err, UdpSocket.allowIp4Fallback(err));
    }
    try std.testing.expectEqual(error.DualStackUnsupported, UdpSocket.socketOptionError(.NOPROTOOPT));
    try std.testing.expectEqual(error.AccessDenied, UdpSocket.socketOptionError(.PERM));
    try std.testing.expectEqual(error.InvalidSocketOption, UdpSocket.socketOptionError(.INVAL));
}

test "transient send errors are narrowly classified without hiding hard failures" {
    for ([_]std.c.E{ .NETUNREACH, .HOSTUNREACH, .NETDOWN }) |err| {
        try std.testing.expectEqual(error.NetworkUnavailable, UdpSocket.sendError(err));
    }
    try std.testing.expectEqual(error.Interrupted, UdpSocket.sendError(.INTR));
    try std.testing.expectEqual(error.WouldBlock, UdpSocket.sendError(.AGAIN));
    for ([_]std.c.E{ .BADF, .ACCES, .INVAL, .NOMEM, .NOTSOCK }) |err| {
        try std.testing.expectEqual(error.SendFailed, UdpSocket.sendError(err));
    }
}

test "port collision advances only within requested range" {
    var occupied = try testBindIp4(61220, 61230);
    defer occupied.close();
    try std.testing.expectError(error.AddressInUse, UdpSocket.bindFamily(posix.AF.INET, occupied.bound_port, occupied.bound_port + 1, false));
    var next = try UdpSocket.bindFamily(posix.AF.INET, occupied.bound_port, occupied.bound_port + 2, false);
    defer next.close();
    try std.testing.expectEqual(occupied.bound_port + 1, next.bound_port);
}
