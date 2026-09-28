// Adapted from mmonad/zmosh, revision 71eba23416bfb443df755ad89d6d06e665ebcd95.
// MIT license; see ../LICENSE and ../UPSTREAM.md.
const std = @import("std");

const log = std.log.scoped(.crypto);

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

pub const key_length = Aead.key_length; // 32 bytes
pub const nonce_length = Aead.nonce_length; // 24 bytes
pub const tag_length = Aead.tag_length; // 16 bytes
pub const Key = [key_length]u8;
pub const Nonce = [nonce_length]u8;

pub const Direction = enum(u1) { to_server = 0, to_client = 1 };

/// 8-byte nonce prefix at the start of each datagram (direction + sequence).
pub const Header = extern struct {
    nonce_prefix: [8]u8,
};

/// Total per-datagram overhead: 8-byte nonce prefix + 16-byte auth tag.
pub const overhead = 8 + tag_length;

// -- Key management ----------------------------------------------------------

pub fn generateKey(io: std.Io) !Key {
    var key: Key = undefined;
    try io.randomSecure(&key);
    return key;
}

const base64 = std.base64.standard;
const encoded_key_len = base64.Encoder.calcSize(key_length);

pub fn keyToBase64(key: Key) [encoded_key_len]u8 {
    var out: [encoded_key_len]u8 = undefined;
    _ = base64.Encoder.encode(&out, &key);
    return out;
}

pub fn keyFromBase64(encoded: []const u8) !Key {
    if ((base64.Decoder.calcSizeForSlice(encoded) catch return error.InvalidKey) != key_length) return error.InvalidKey;
    var key: Key = undefined;
    base64.Decoder.decode(&key, encoded) catch return error.InvalidKey;
    return key;
}

// -- Nonce construction ------------------------------------------------------

/// Build a 24-byte XChaCha20 nonce from direction + sequence.
/// First 16 bytes are zero; last 8 bytes are big-endian (direction bit | seq).
pub fn buildNonce(direction: Direction, sequence: u63) Nonce {
    const val: u64 = (@as(u64, @intFromEnum(direction)) << 63) | @as(u64, sequence);
    var nonce: Nonce = .{0} ** nonce_length;
    std.mem.writeInt(u64, nonce[16..24], val, .big);
    return nonce;
}

/// Extract the 8-byte nonce prefix from the last 8 bytes of a full nonce.
fn noncePrefix(nonce: Nonce) [8]u8 {
    return nonce[16..24].*;
}

/// Rebuild a full 24-byte nonce from an 8-byte prefix (zero-pad first 16 bytes).
fn nonceFromPrefix(prefix: [8]u8) Nonce {
    var nonce: Nonce = .{0} ** nonce_length;
    nonce[16..24].* = prefix;
    return nonce;
}

// -- Low-level encrypt / decrypt ---------------------------------------------

pub fn encrypt(key: Key, nonce: Nonce, plaintext: []const u8, ad: []const u8, out: []u8) void {
    std.debug.assert(out.len >= plaintext.len + tag_length);
    Aead.encrypt(out[0..plaintext.len], out[plaintext.len..][0..tag_length], plaintext, ad, nonce, key);
}

pub fn decrypt(key: Key, nonce: Nonce, ciphertext_with_tag: []const u8, ad: []const u8, out: []u8) !void {
    if (ciphertext_with_tag.len < tag_length) return error.AuthenticationFailed;
    const ct_len = ciphertext_with_tag.len - tag_length;
    std.debug.assert(out.len >= ct_len);
    Aead.decrypt(out[0..ct_len], ciphertext_with_tag[0..ct_len], ciphertext_with_tag[ct_len..][0..tag_length].*, ad, nonce, key) catch return error.AuthenticationFailed;
}

// -- Datagram helpers --------------------------------------------------------

pub const DecodeResult = struct {
    seq: u63,
    plaintext: []u8,
};

/// Build an encrypted datagram: nonce_prefix(8) || ciphertext || tag(16).
pub fn encodeDatagram(key: Key, direction: Direction, seq: u63, plaintext: []const u8, buf: []u8) ![]u8 {
    const total = 8 + plaintext.len + tag_length;
    if (buf.len < total) return error.BufferTooSmall;

    const nonce = buildNonce(direction, seq);
    const prefix = noncePrefix(nonce);

    // Write nonce prefix as first 8 bytes.
    buf[0..8].* = prefix;

    // Encrypt into buf[8..], using nonce prefix as associated data.
    encrypt(key, nonce, plaintext, &prefix, buf[8..][0 .. plaintext.len + tag_length]);

    return buf[0..total];
}

/// Parse and decrypt a datagram produced by `encodeDatagram`.
pub fn decodeDatagram(key: Key, expected_direction: Direction, datagram: []const u8, buf: []u8) !DecodeResult {
    if (datagram.len < overhead) return error.DatagramTooShort;

    const prefix = datagram[0..8].*;
    const nonce = nonceFromPrefix(prefix);

    // Extract direction + seq from the prefix.
    const val = std.mem.readInt(u64, &prefix, .big);
    const dir_bit: u1 = @truncate(val >> 63);
    if (dir_bit != @intFromEnum(expected_direction)) return error.DirectionMismatch;
    const seq: u63 = @truncate(val);

    const ct_with_tag = datagram[8..];
    const pt_len = ct_with_tag.len - tag_length;
    if (buf.len < pt_len) return error.BufferTooSmall;

    decrypt(key, nonce, ct_with_tag, &prefix, buf) catch return error.AuthenticationFailed;

    return .{ .seq = seq, .plaintext = buf[0..pt_len] };
}

// -- Tests -------------------------------------------------------------------

test "round-trip encrypt/decrypt" {
    const key = try generateKey(std.testing.io);
    const nonce = buildNonce(.to_server, 1);
    const plaintext = "hello, zmx!";
    var ct_buf: [plaintext.len + tag_length]u8 = undefined;
    var pt_buf: [plaintext.len]u8 = undefined;

    encrypt(key, nonce, plaintext, "", &ct_buf);
    try decrypt(key, nonce, &ct_buf, "", &pt_buf);
    try std.testing.expectEqualStrings(plaintext, &pt_buf);
}

test "tampered ciphertext fails authentication" {
    const key = try generateKey(std.testing.io);
    const nonce = buildNonce(.to_client, 42);
    const plaintext = "secret";
    var ct_buf: [plaintext.len + tag_length]u8 = undefined;
    var pt_buf: [plaintext.len]u8 = undefined;

    encrypt(key, nonce, plaintext, "", &ct_buf);
    ct_buf[0] ^= 0xff; // tamper
    try std.testing.expectError(error.AuthenticationFailed, decrypt(key, nonce, &ct_buf, "", &pt_buf));
}

test "wrong key fails" {
    const key = try generateKey(std.testing.io);
    const wrong_key = try generateKey(std.testing.io);
    const nonce = buildNonce(.to_server, 0);
    const plaintext = "data";
    var ct_buf: [plaintext.len + tag_length]u8 = undefined;
    var pt_buf: [plaintext.len]u8 = undefined;

    encrypt(key, nonce, plaintext, "", &ct_buf);
    try std.testing.expectError(error.AuthenticationFailed, decrypt(wrong_key, nonce, &ct_buf, "", &pt_buf));
}

test "nonce direction bit" {
    const n0 = buildNonce(.to_server, 100);
    const n1 = buildNonce(.to_client, 100);
    // The last 8 bytes should differ only in the MSB.
    const v0 = std.mem.readInt(u64, n0[16..24], .big);
    const v1 = std.mem.readInt(u64, n1[16..24], .big);
    try std.testing.expect(v0 & (1 << 63) == 0);
    try std.testing.expect(v1 & (1 << 63) != 0);
    try std.testing.expectEqual(v0 ^ (1 << 63), v1);
}

test "base64 key round-trip" {
    const key = try generateKey(std.testing.io);
    const encoded = keyToBase64(key);
    const decoded = try keyFromBase64(&encoded);
    try std.testing.expectEqual(key, decoded);
}

test "datagram round-trip" {
    const key = try generateKey(std.testing.io);
    const plaintext = "payload data";
    var enc_buf: [overhead + plaintext.len]u8 = undefined;
    var dec_buf: [plaintext.len]u8 = undefined;

    const datagram = try encodeDatagram(key, .to_server, 7, plaintext, &enc_buf);
    const result = try decodeDatagram(key, .to_server, datagram, &dec_buf);
    try std.testing.expectEqual(@as(u63, 7), result.seq);
    try std.testing.expectEqualStrings(plaintext, result.plaintext);
}

test "datagram direction mismatch" {
    const key = try generateKey(std.testing.io);
    const plaintext = "x";
    var enc_buf: [overhead + plaintext.len]u8 = undefined;
    var dec_buf: [plaintext.len]u8 = undefined;

    const datagram = try encodeDatagram(key, .to_server, 1, plaintext, &enc_buf);
    try std.testing.expectError(error.DirectionMismatch, decodeDatagram(key, .to_client, datagram, &dec_buf));
}

test "datagram tamper fails" {
    const key = try generateKey(std.testing.io);
    const plaintext = "abc";
    var enc_buf: [overhead + plaintext.len]u8 = undefined;
    var dec_buf: [plaintext.len]u8 = undefined;

    const datagram = try encodeDatagram(key, .to_client, 99, plaintext, &enc_buf);
    var tampered: [overhead + plaintext.len]u8 = undefined;
    @memcpy(&tampered, datagram);
    tampered[10] ^= 0x01;
    try std.testing.expectError(error.AuthenticationFailed, decodeDatagram(key, .to_client, &tampered, &dec_buf));
}

test "key decoder rejects short decoded keys" {
    try std.testing.expectError(error.InvalidKey, keyFromBase64("YQ=="));
    try std.testing.expectError(error.InvalidKey, keyFromBase64(""));
    try std.testing.expectError(error.InvalidKey, keyFromBase64("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
}

// Captured by running the unmodified pinned upstream crypto.zig encoder at
// 71eba23416bfb443df755ad89d6d06e665ebcd95 with key bytes 0..31 and seq below.
test "pinned upstream datagram known answers in both directions" {
    var key: Key = undefined;
    for (&key, 0..) |*byte, i| byte.* = @intCast(i);
    const plaintext = "zmosh pinned vector";
    const vectors = [_][]const u8{
        "0000000123456789b6cb064396d695e2d6eabf3293c2802ff80c2e1d35e34795571a1502595107bc8afa6b",
        "800000012345678971943573dfbd6321964a1b7ffd5b94989fb6057aeb71c529bcbb8030954da8e0f0f1ca",
    };
    for (vectors, [_]Direction{ .to_server, .to_client }) |hex, direction| {
        var expected: [overhead + plaintext.len]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, hex);
        var encrypted: [expected.len]u8 = undefined;
        const packet = try encodeDatagram(key, direction, 0x123456789, plaintext, &encrypted);
        try std.testing.expectEqualSlices(u8, &expected, packet);
        var decoded: [plaintext.len]u8 = undefined;
        const result = try decodeDatagram(key, direction, &expected, &decoded);
        try std.testing.expectEqualStrings(plaintext, result.plaintext);
        try std.testing.expectEqual(@as(u63, 0x123456789), result.seq);
    }
}
