const std = @import("std");
const testing = std.testing;

pub const Directory = struct {
    /// The session's working directory in OSC 7 form, `file://<host><path>`.
    /// Kept as a URI rather than a path so `zmx list` shows the host, which is
    /// what tells you a session is inside SSH. Points into `cwd_buf` once set,
    /// so a Daemon must not be copied by value after that.
    uri: []const u8 = "",
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,

    /// Accepts either an OSC 7 value (`file://<host><path>`, percent-encoded)
    /// or a path.
    ///
    /// The value is copied, so callers may pass a temporary.
    pub fn update(self: *Directory, new_cwd: ?[]const u8) void {
        const value = new_cwd orelse return;
        if (value.len != 0 and std.mem.eql(u8, self.uri, value)) return;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&host_buf) catch "";
        const cwd = parseOsc7Cwd(&buf, value, hostname) orelse {
            std.log.warn("ignoring unusable cwd={s}", .{value});
            return;
        };

        // Store the URI form. A caller that handed us a plain path gets one
        // built here, so `cwd` has the same shape no matter the source. A value
        // that already was a URI is kept verbatim, so `list` shows what the
        // shell actually reported.
        self.uri = if (std.fs.path.isAbsolute(value))
            toOsc7Cwd(&self.cwd_buf, value, hostname) orelse return
        else blk: {
            if (value.len > self.cwd_buf.len) return;
            @memcpy(self.cwd_buf[0..value.len], value);
            break :blk self.cwd_buf[0..value.len];
        };

        std.log.info("set cwd={s} path={s}", .{ self.uri, if (cwd.is_local) cwd.path else "" });
    }

    /// The same directory as a path that can be opened: percent-decoding
    /// applied, scheme and host stripped. Returns null for a remote host.
    pub fn localPath(self: *const Directory, buf: []u8) ?[]const u8 {
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&host_buf) catch "";
        const cwd = parseOsc7Cwd(buf, self.uri, hostname) orelse return null;
        return if (cwd.is_local) cwd.path else null;
    }
};

/// Emit the terminal's pwd as OSC 7.
///
/// This replaces the formatter's own `extra.pwd`, which writes
/// `terminal.pwd.items` verbatim. `Terminal.setPwd` appends a NUL sentinel to
/// that buffer, so the formatter's OSC 7 carries a stray `\x00` before the
/// terminator. `getPwd()` returns the same bytes without the sentinel.
///
/// The NUL is not cosmetic: a client that records what it receives (kitty
/// writing its session file, for one) persists the NUL and then fails to parse
/// its own state back. See https://github.com/neurosnap/zmx/issues/222.
pub fn writeCwd(writer: *std.Io.Writer, reported_cwd: ?[]const u8) void {
    const pwd = reported_cwd orelse return;
    if (pwd.len == 0) return;
    writer.print("\x1b]7;{s}\x1b\\", .{pwd}) catch |err| {
        std.log.warn("failed to format pwd err={s}", .{@errorName(err)});
    };
}

const Cwd = struct {
    /// A filesystem path, percent-decoded, with no scheme or host.
    path: []const u8,
    /// True when the OSC 7 host is this machine, so `path` names a directory we
    /// can actually chdir into. OSC 7 crosses SSH boundaries, so a session that
    /// ssh'd elsewhere reports a path that does not exist locally.
    is_local: bool,
};

/// parseOsc7Cwd turns an OSC 7 value into a path that can be opened.
///
/// The value looks like `file://<host><path>` with the path percent-encoded, so
/// it cannot be handed to `openDirAbsolute` as-is: the escaping is never
/// decoded and any directory whose name needed it fails to open.
///
/// A plain absolute path is accepted and passed through, since a caller may
/// hand us one directly before the session has reported an OSC 7.
///
/// `buf` holds the decoded path, so the result stays valid after the source
/// value changes. Returns null when the value is not a path we can use.
fn parseOsc7Cwd(buf: []u8, value: []const u8, hostname: []const u8) ?Cwd {
    if (value.len == 0) return null;

    if (std.fs.path.isAbsolute(value)) {
        if (value.len > buf.len) return null;
        @memcpy(buf[0..value.len], value);
        return .{ .path = buf[0..value.len], .is_local = true };
    }

    const uri = std.Uri.parse(value) catch return null;
    // kitty emits kitty-shell-cwd:// from its own shell integration, and
    // accepts it alongside file:// on the way back in.
    if (!std.mem.eql(u8, uri.scheme, "file") and
        !std.mem.eql(u8, uri.scheme, "kitty-shell-cwd")) return null;

    const decoded = uri.path.toRaw(buf) catch return null;
    if (!std.fs.path.isAbsolute(decoded)) return null;
    // toRaw returns the input slice when there was nothing to decode, and that
    // slice is owned by the caller of this fn, so copy it into buf either way.
    const path = if (decoded.ptr == buf.ptr) decoded else blk: {
        if (decoded.len > buf.len) return null;
        std.mem.copyForwards(u8, buf[0..decoded.len], decoded);
        break :blk buf[0..decoded.len];
    };

    return .{ .path = path, .is_local = isLocalHost(uri.host, hostname) };
}

fn isLocalHost(host: ?std.Uri.Component, hostname: []const u8) bool {
    // file:///path omits the host, which conventionally means the local machine.
    const component = host orelse return true;
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const value = component.toRaw(&host_buf) catch return false;
    if (value.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(value, "localhost")) return true;
    if (std.ascii.eqlIgnoreCase(value, hostname)) return true;
    // gethostname often reports a short name while OSC 7 carries the FQDN
    // (or the reverse), so fall back to comparing the first label.
    const value_label = value[0 .. std.mem.indexOfScalar(u8, value, '.') orelse value.len];
    const host_label = hostname[0 .. std.mem.indexOfScalar(u8, hostname, '.') orelse hostname.len];
    return host_label.len > 0 and std.ascii.eqlIgnoreCase(value_label, host_label);
}

/// toOsc7Cwd renders a plain path as the OSC 7 form, `file://<host><path>`.
///
/// The daemon stores its cwd in this form so `zmx list` shows the host, which
/// is how you can tell at a glance that a session is inside SSH. Callers that
/// only have a local path (`zmx run`, `zmx attach`) go through this so the
/// stored value has one shape regardless of where it came from.
///
/// Returns null when the result would not fit in `buf`.
fn toOsc7Cwd(buf: []u8, path: []const u8, hostname: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("file://{s}", .{hostname}) catch return null;
    // Percent-encode so a path with a space or a `%` in it round-trips back
    // through parseOsc7Cwd unchanged.
    std.Uri.Component.percentEncode(&w, path, isPathChar) catch return null;
    return w.buffered();
}

/// Characters that need no escaping in a URI path. RFC 3986 pchar, minus the
/// sub-delims that a shell would find surprising to see left raw in `zmx list`.
fn isPathChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '-', '.', '_', '~', '/', ':', '@' => true,
        else => false,
    };
}

test "parseOsc7Cwd" {
    const Case = struct {
        name: []const u8,
        value: []const u8,
        hostname: []const u8,
        expected: ?Cwd,
    };

    const cases = [_]Case{
        .{
            .name = "local file uri",
            .value = "file://myhost/private/tmp",
            .hostname = "myhost",
            .expected = .{ .path = "/private/tmp", .is_local = true },
        },
        .{
            .name = "percent-encoded path is decoded",
            .value = "file://myhost/tmp/zmx%20spaced%20dir",
            .hostname = "myhost",
            .expected = .{ .path = "/tmp/zmx spaced dir", .is_local = true },
        },
        .{
            .name = "kitty scheme",
            .value = "kitty-shell-cwd://myhost/private/tmp",
            .hostname = "myhost",
            .expected = .{ .path = "/private/tmp", .is_local = true },
        },
        .{
            .name = "remote host keeps the path but is not local",
            .value = "file://otherhost/home/me",
            .hostname = "myhost",
            .expected = .{ .path = "/home/me", .is_local = false },
        },
        .{
            .name = "empty host means local",
            .value = "file:///private/tmp",
            .hostname = "myhost",
            .expected = .{ .path = "/private/tmp", .is_local = true },
        },
        .{
            .name = "localhost means local",
            .value = "file://localhost/private/tmp",
            .hostname = "myhost",
            .expected = .{ .path = "/private/tmp", .is_local = true },
        },
        .{
            .name = "fqdn matches a short hostname",
            .value = "file://myhost.local/private/tmp",
            .hostname = "myhost",
            .expected = .{ .path = "/private/tmp", .is_local = true },
        },
        .{
            .name = "short host matches an fqdn hostname",
            .value = "file://myhost/private/tmp",
            .hostname = "myhost.lan",
            .expected = .{ .path = "/private/tmp", .is_local = true },
        },
        .{
            .name = "host comparison ignores case",
            .value = "file://MyHost/private/tmp",
            .hostname = "myhost",
            .expected = .{ .path = "/private/tmp", .is_local = true },
        },
        .{
            .name = "plain absolute path passes through",
            .value = "/private/tmp",
            .hostname = "myhost",
            .expected = .{ .path = "/private/tmp", .is_local = true },
        },
        .{
            .name = "empty value",
            .value = "",
            .hostname = "myhost",
            .expected = null,
        },
        .{
            .name = "relative path",
            .value = "some/dir",
            .hostname = "myhost",
            .expected = null,
        },
        .{
            .name = "unsupported scheme",
            .value = "http://myhost/private/tmp",
            .hostname = "myhost",
            .expected = null,
        },
        .{
            .name = "uri without a path",
            .value = "file://myhost",
            .hostname = "myhost",
            .expected = null,
        },
    };

    for (cases) |c| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const actual = parseOsc7Cwd(&buf, c.value, c.hostname);
        testing.expectEqualDeep(c.expected, actual) catch |err| {
            std.debug.print("case: {s}\n", .{c.name});
            return err;
        };
    }
}

test "parseOsc7Cwd result survives the source value changing" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var value: [32]u8 = undefined;
    const src = "file://myhost/private/tmp";
    @memcpy(value[0..src.len], src);

    const cwd = parseOsc7Cwd(&buf, value[0..src.len], "myhost") orelse
        return error.TestUnexpectedNull;

    @memset(&value, 'x');
    try testing.expectEqualDeep(Cwd{ .path = "/private/tmp", .is_local = true }, cwd);
}

test "parseOsc7Cwd rejects a path longer than the buffer" {
    var buf: [8]u8 = undefined;
    try testing.expectEqual(
        @as(?Cwd, null),
        parseOsc7Cwd(&buf, "file://myhost/a/very/long/path", "myhost"),
    );
    try testing.expectEqual(
        @as(?Cwd, null),
        parseOsc7Cwd(&buf, "/a/very/long/path", "myhost"),
    );
}

test "toOsc7Cwd" {
    const Case = struct {
        name: []const u8,
        path: []const u8,
        expected: ?[]const u8,
    };

    const cases = [_]Case{
        .{
            .name = "plain path",
            .path = "/private/tmp",
            .expected = "file://myhost/private/tmp",
        },
        .{
            .name = "space is encoded",
            .path = "/tmp/zmx spaced dir",
            .expected = "file://myhost/tmp/zmx%20spaced%20dir",
        },
        .{
            .name = "percent is encoded so it round-trips",
            .path = "/tmp/100%",
            .expected = "file://myhost/tmp/100%25",
        },
        .{
            .name = "unreserved characters are left alone",
            .path = "/tmp/a-b_c.d~e",
            .expected = "file://myhost/tmp/a-b_c.d~e",
        },
    };

    for (cases) |c| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        testing.expectEqualDeep(c.expected, toOsc7Cwd(&buf, c.path, "myhost")) catch |err| {
            std.debug.print("case: {s}\n", .{c.name});
            return err;
        };
    }
}

test "toOsc7Cwd returns null when the result would not fit" {
    var buf: [8]u8 = undefined;
    try testing.expectEqual(
        @as(?[]const u8, null),
        toOsc7Cwd(&buf, "/a/very/long/path", "myhost"),
    );
}

test "toOsc7Cwd round-trips through parseOsc7Cwd" {
    const paths = [_][]const u8{
        "/private/tmp",
        "/tmp/zmx spaced dir",
        "/tmp/100%",
        "/tmp/a-b_c.d~e",
        "/tmp/quote'and\"dquote",
    };

    for (paths) |path| {
        var enc_buf: [std.fs.max_path_bytes]u8 = undefined;
        const uri = toOsc7Cwd(&enc_buf, path, "myhost") orelse
            return error.TestUnexpectedNull;

        var dec_buf: [std.fs.max_path_bytes]u8 = undefined;
        testing.expectEqualDeep(
            Cwd{ .path = path, .is_local = true },
            parseOsc7Cwd(&dec_buf, uri, "myhost"),
        ) catch |err| {
            std.debug.print("path: {s} uri: {s}\n", .{ path, uri });
            return err;
        };
    }
}
