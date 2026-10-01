// Adapted from mmonad/zmosh, revision 71eba23416bfb443df755ad89d6d06e665ebcd95.
// MIT license; see ../LICENSE and ../UPSTREAM.md.
const std = @import("std");

pub const version: u8 = 1;
pub const max_payload_len: usize = 1100;
pub const header_len: usize = 20;

pub const Channel = enum(u8) {
    heartbeat = 0,
    reliable_ipc = 1,
    output = 2,
    control = 3,
};

pub const Packet = struct {
    channel: Channel,
    seq: u32,
    ack: u32,
    ack_bits: u32,
    payload: []const u8,
};

pub const ReliableAction = enum {
    accept,
    duplicate,
    stale,
};

pub const RecvState = struct {
    latest: u32 = 0,
    mask: u32 = 0,
    has_latest: bool = false,

    pub fn onReliable(self: *RecvState, seq: u32) ReliableAction {
        if (!self.has_latest) {
            self.latest = seq;
            self.mask = 0;
            self.has_latest = true;
            return .accept;
        }

        if (seq > self.latest) {
            const shift = seq - self.latest;
            if (shift > 32) {
                self.mask = 0;
            } else {
                self.mask = if (shift == 32) 0 else self.mask << @intCast(shift);
                self.mask |= @as(u32, 1) << @intCast(shift - 1);
            }
            self.latest = seq;
            return .accept;
        }

        const diff = self.latest - seq;
        if (diff == 0) return .duplicate;
        if (diff > 32) return .stale;

        const bit: u32 = @as(u32, 1) << @intCast(diff - 1);
        if (self.mask & bit != 0) return .duplicate;
        self.mask |= bit;
        return .accept;
    }

    pub fn ack(self: *const RecvState) u32 {
        return if (self.has_latest) self.latest else 0;
    }

    pub fn ackBits(self: *const RecvState) u32 {
        return if (self.has_latest) self.mask else 0;
    }
};

pub const ReliableSend = struct {
    alloc: std.mem.Allocator,
    next_seq: u64 = 1,
    pending: std.ArrayList(Pending),

    const Pending = struct {
        seq: u32,
        sent_ns: i64,
        retries: u8,
        packet: []u8,
    };

    pub fn init(alloc: std.mem.Allocator) !ReliableSend {
        return .{
            .alloc = alloc,
            .pending = try std.ArrayList(Pending).initCapacity(alloc, 16),
        };
    }

    pub fn deinit(self: *ReliableSend) void {
        for (self.pending.items) |p| {
            self.alloc.free(p.packet);
        }
        self.pending.deinit(self.alloc);
    }

    pub fn oldestSeq(self: *const ReliableSend) ?u32 {
        return if (self.pending.items.len == 0) null else self.pending.items[0].seq;
    }

    pub fn canSend(self: *const ReliableSend) bool {
        if (self.next_seq > std.math.maxInt(u32)) return false;
        if (self.oldestSeq()) |oldest| return self.next_seq - oldest < 32;
        return true;
    }

    pub fn hasPending(self: *const ReliableSend) bool {
        return self.pending.items.len > 0;
    }

    pub fn buildAndTrack(
        self: *ReliableSend,
        channel: Channel,
        payload: []const u8,
        ack_seq: u32,
        ack_bits: u32,
        now_ns: i64,
    ) ![]const u8 {
        if (self.next_seq > std.math.maxInt(u32)) return error.SequenceExhausted;
        if (!self.canSend()) return error.WindowFull;
        if (channel != .reliable_ipc) return error.InvalidChannel;
        if (payload.len > max_payload_len) return error.PayloadTooLarge;
        const seq: u32 = @intCast(self.next_seq);

        const packet = try self.alloc.alloc(u8, header_len + payload.len);
        errdefer self.alloc.free(packet);
        writeHeader(packet[0..header_len], channel, seq, ack_seq, ack_bits, payload.len);
        if (payload.len > 0) {
            @memcpy(packet[header_len..], payload);
        }

        try self.pending.append(self.alloc, .{
            .seq = seq,
            .sent_ns = now_ns,
            .retries = 0,
            .packet = packet,
        });

        self.next_seq += 1;
        return packet;
    }

    pub fn ack(self: *ReliableSend, ack_seq: u32, ack_bits: u32) void {
        var i: usize = self.pending.items.len;
        while (i > 0) {
            i -= 1;
            const p = self.pending.items[i];
            if (isAcked(p.seq, ack_seq, ack_bits)) {
                self.alloc.free(p.packet);
                _ = self.pending.orderedRemove(i);
            }
        }
    }

    pub fn collectRetransmits(
        self: *ReliableSend,
        alloc: std.mem.Allocator,
        now_ns: i64,
        rto_us: i64,
    ) !std.ArrayList([]const u8) {
        var out = try std.ArrayList([]const u8).initCapacity(alloc, 32);
        errdefer out.deinit(alloc);
        const interval_ns = @max(@as(i64, 1), rto_us) * std.time.ns_per_us;

        for (self.pending.items) |*p| {
            if (now_ns - p.sent_ns >= interval_ns) {
                p.sent_ns = now_ns;
                p.retries +%= 1;
                try out.append(alloc, p.packet);
            }
        }

        return out;
    }

    fn isAcked(seq: u32, ack_seq: u32, ack_bits: u32) bool {
        if (ack_seq == 0) return false;
        if (seq == ack_seq) return true;
        if (seq > ack_seq) return false;

        const diff = ack_seq - seq;
        if (diff == 0) return true;
        if (diff > 32) return false;

        const bit: u32 = @as(u32, 1) << @intCast(diff - 1);
        return (ack_bits & bit) != 0;
    }
};

pub fn writeHeader(dst: []u8, channel: Channel, seq: u32, ack: u32, ack_bits: u32, payload_len: usize) void {
    std.debug.assert(dst.len >= header_len);
    std.debug.assert(payload_len <= std.math.maxInt(u16));

    dst[0] = version;
    dst[1] = @intFromEnum(channel);
    dst[2] = 0;
    dst[3] = 0;

    std.mem.writeInt(u32, dst[4..8], seq, .big);
    std.mem.writeInt(u32, dst[8..12], ack, .big);
    std.mem.writeInt(u32, dst[12..16], ack_bits, .big);
    std.mem.writeInt(u16, dst[16..18], @intCast(payload_len), .big);
    std.mem.writeInt(u16, dst[18..20], 0, .big);
}

pub fn parsePacket(data: []const u8) !Packet {
    if (data.len < header_len) return error.PacketTooShort;
    if (data[0] != version) return error.UnsupportedVersion;

    const channel_int = data[1];
    const channel = std.enums.fromInt(Channel, channel_int) orelse return error.InvalidChannel;

    const seq = std.mem.readInt(u32, data[4..8], .big);
    const ack = std.mem.readInt(u32, data[8..12], .big);
    const ack_bits = std.mem.readInt(u32, data[12..16], .big);
    const len = std.mem.readInt(u16, data[16..18], .big);

    if (len > max_payload_len) return error.PayloadTooLarge;
    if (data.len != header_len + len) return error.InvalidLength;

    return .{
        .channel = channel,
        .seq = seq,
        .ack = ack,
        .ack_bits = ack_bits,
        .payload = data[header_len..],
    };
}

pub fn buildUnreliable(
    channel: Channel,
    seq: u32,
    ack: u32,
    ack_bits: u32,
    payload: []const u8,
    out: []u8,
) ![]const u8 {
    if (payload.len > max_payload_len) return error.PayloadTooLarge;
    const total = header_len + payload.len;
    if (out.len < total) return error.BufferTooSmall;
    writeHeader(out[0..header_len], channel, seq, ack, ack_bits, payload.len);
    if (payload.len > 0) {
        @memcpy(out[header_len..total], payload);
    }
    return out[0..total];
}

test "transport header round trip" {
    var buf: [64]u8 = undefined;
    const payload = "abc";
    const pkt = try buildUnreliable(.output, 7, 6, 0x55, payload, &buf);
    const parsed = try parsePacket(pkt);
    try std.testing.expect(parsed.channel == .output);
    try std.testing.expectEqual(@as(u32, 7), parsed.seq);
    try std.testing.expectEqual(@as(u32, 6), parsed.ack);
    try std.testing.expectEqual(@as(u32, 0x55), parsed.ack_bits);
    try std.testing.expectEqualStrings(payload, parsed.payload);
}

test "reliable recv window" {
    var recv = RecvState{};
    try std.testing.expect(recv.onReliable(10) == .accept);
    try std.testing.expect(recv.onReliable(9) == .accept);
    try std.testing.expect(recv.onReliable(9) == .duplicate);
    try std.testing.expect(recv.onReliable(11) == .accept);
    try std.testing.expectEqual(@as(u32, 11), recv.ack());
}

test "send window remains anchored to missing oldest across gaps 31 32 33" {
    var sender = try ReliableSend.init(std.testing.allocator);
    defer sender.deinit();
    for (0..32) |_| _ = try sender.buildAndTrack(.reliable_ipc, "x", 0, 0, 0);
    sender.ack(32, 0x3fffffff); // Admit 2..32, but keep 1 outstanding.
    try std.testing.expectEqual(@as(?u32, 1), sender.oldestSeq());
    try std.testing.expectError(error.WindowFull, sender.buildAndTrack(.reliable_ipc, "x", 0, 0, 0));
    sender.ack(33, 0); // An impossible future ACK must not free sequence 1.
    try std.testing.expect(!sender.canSend());
    sender.ack(32, 0x40000000); // Gap 31 acknowledges 1.
    try std.testing.expect(sender.canSend());
    try std.testing.expect(ReliableSend.isAcked(1, 33, 0x80000000));
    try std.testing.expect(!ReliableSend.isAcked(1, 34, 0xffffffff));
}

test "ordered receiver retains reordering and refuses gaps 32 and 33" {
    var receiver = OrderedRecv{};
    try std.testing.expectEqual(.accept, try receiver.accept(32, "last"));
    try std.testing.expectEqual(.stale, try receiver.accept(33, "outside"));
    try std.testing.expectEqual(.stale, try receiver.accept(34, "outside"));
    try std.testing.expectEqual(@as(u32, 32), receiver.ack());
    try std.testing.expect(receiver.peek() == null);
    try std.testing.expectEqual(.accept, try receiver.accept(2, "two"));
    try std.testing.expect(receiver.peek() == null);
    try std.testing.expectEqual(.accept, try receiver.accept(1, "one"));
    try std.testing.expectEqualStrings("one", receiver.peek().?);
    try std.testing.expectEqual(.duplicate, try receiver.accept(1, "duplicate"));
    receiver.pop();
    try std.testing.expectEqualStrings("two", receiver.peek().?);
    receiver.pop();
    try std.testing.expect(receiver.peek() == null);
}

test "reliable sequence exhaustion cannot wrap" {
    var sender = try ReliableSend.init(std.testing.allocator);
    defer sender.deinit();
    sender.next_seq = std.math.maxInt(u32);
    _ = try sender.buildAndTrack(.reliable_ipc, "last", 0, 0, 0);
    try std.testing.expectError(error.SequenceExhausted, sender.buildAndTrack(.reliable_ipc, "wrap", 0, 0, 0));
}

test "ACK mask preserves previous latest at distance 32" {
    var recv = RecvState{};
    _ = recv.onReliable(1);
    _ = recv.onReliable(33);
    try std.testing.expectEqual(@as(u32, 0x80000000), recv.ackBits());
}

/// Receipt ACKs represent retained capacity. The caller pops only after the
/// downstream sink has accepted the whole payload. No allocation on receive.
pub const OrderedRecv = struct {
    const Slot = struct {
        seq: u32 = 0,
        len: usize = 0,
        bytes: [max_payload_len]u8 = undefined,
    };
    slots: [32]Slot = .{Slot{}} ** 32,
    next_seq: u64 = 1,
    received: RecvState = .{},

    pub fn accept(self: *OrderedRecv, seq: u32, payload: []const u8) !ReliableAction {
        if (seq == 0) return error.InvalidSequence;
        if (payload.len > max_payload_len) return error.PayloadTooLarge;
        if (seq < self.next_seq) return .duplicate;
        if (@as(u64, seq) - self.next_seq >= self.slots.len) return .stale;
        const slot = &self.slots[seq % self.slots.len];
        if (slot.seq == seq) return .duplicate;
        std.debug.assert(slot.seq == 0);
        @memcpy(slot.bytes[0..payload.len], payload);
        slot.len = payload.len;
        slot.seq = seq;
        _ = self.received.onReliable(seq);
        return .accept;
    }

    pub fn peek(self: *const OrderedRecv) ?[]const u8 {
        if (self.next_seq > std.math.maxInt(u32)) return null;
        const slot = &self.slots[self.next_seq % self.slots.len];
        return if (slot.seq == self.next_seq) slot.bytes[0..slot.len] else null;
    }

    pub fn pop(self: *OrderedRecv) void {
        std.debug.assert(self.peek() != null);
        self.slots[self.next_seq % self.slots.len].seq = 0;
        self.next_seq += 1;
    }

    pub fn ack(self: *const OrderedRecv) u32 {
        return self.received.ack();
    }
    pub fn ackBits(self: *const OrderedRecv) u32 {
        return self.received.ackBits();
    }
};

test "full receive window retains every packet until explicit drain" {
    var receiver = OrderedRecv{};
    var seq: u32 = 32;
    while (seq > 0) : (seq -= 1) {
        const payload = [_]u8{@intCast(seq)};
        try std.testing.expectEqual(.accept, try receiver.accept(seq, &payload));
    }
    try std.testing.expectEqual(@as(u32, 0x7fffffff), receiver.ackBits());
    try std.testing.expectEqual(.stale, try receiver.accept(33, "outside"));
    for (1..33) |expected| {
        try std.testing.expectEqual(@as(u8, @intCast(expected)), receiver.peek().?[0]);
        receiver.pop();
    }
    try std.testing.expect(receiver.peek() == null);
    try std.testing.expectEqual(.accept, try receiver.accept(33, "resumed"));
    try std.testing.expectEqualStrings("resumed", receiver.peek().?);
    try std.testing.expectError(error.InvalidSequence, receiver.accept(0, "zero"));
}

test "oversize receive is never acknowledged" {
    var receiver = OrderedRecv{};
    const oversized = [_]u8{0} ** (max_payload_len + 1);
    try std.testing.expectError(error.PayloadTooLarge, receiver.accept(1, &oversized));
    try std.testing.expectEqual(@as(u32, 0), receiver.ack());
    try std.testing.expect(receiver.peek() == null);
}
