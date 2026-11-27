/// Cfg is zmx's configuration container.
///
/// The purpose of this container is to hold anything that can be modified by the user.
pub const Cfg = @This();

const std = @import("std");
const lib_posix = @import("posix.zig");
const cross = @import("cross");
const has_daemon = @import("build_options").has_daemon;
pub const CapabilityDefinition = if (has_daemon) @import("capability-api").Definition else void;
const registry = @import("capabilities/registry.zig");

socket_dir: []const u8,
log_dir: []const u8,
capabilities: []const CapabilityDefinition = &.{},
max_scrollback_lines: usize = 10_000,
dir_mode: u32 = 0o750,
log_mode: u32 = 0o640,
tracked_envs: []const u8 = "DISPLAY,SSH_AUTH_SOCK,SSH_AGENT_PID,SSH_CONNECTION,WINDOWID,XAUTHORITY,KITTY_LISTEN_ON,KITTY_PID,KITTY_WINDOW_ID",

pub fn init(alloc: std.mem.Allocator, io: std.Io) !Cfg {
    return initWithOptionalCapabilities(alloc, io, &.{});
}

/// Read configuration for a new daemon, including required and optional capabilities.
/// The supplied list selects optional additions to the registry's always-active
/// capabilities. The returned configuration owns the assembled list and releases
/// it in 'deinit'.
pub fn initWithOptionalCapabilities(alloc: std.mem.Allocator, io: std.Io, definitions: []const CapabilityDefinition) !Cfg {
    const socket_dir = try socketDir(alloc);
    errdefer alloc.free(socket_dir);
    const log_dir = try logDir(alloc);
    errdefer alloc.free(log_dir);

    const dir_mode = if (lib_posix.getenv("ZMX_DIR_MODE")) |m|
        std.fmt.parseInt(u32, m, 8) catch 0o750
    else
        0o750;

    const log_mode = if (lib_posix.getenv("ZMX_LOG_MODE")) |m|
        std.fmt.parseInt(u32, m, 8) catch 0o640
    else
        0o640;

    // Required behavior is assembled here for both CLI and library callers.
    // Neither an empty optional list nor a different caller can remove it.
    const capabilities: []const CapabilityDefinition = if (has_daemon)
        try registry.select(alloc, definitions)
    else
        &.{};
    errdefer alloc.free(capabilities);

    var cfg = Cfg{
        .capabilities = capabilities,
        .socket_dir = socket_dir,
        .log_dir = log_dir,
        .dir_mode = dir_mode,
        .log_mode = log_mode,
    };

    try cfg.mkdir(io);

    return cfg;
}

fn socketDir(alloc: std.mem.Allocator) ![]const u8 {
    const tmpdir = std.mem.trimEnd(u8, lib_posix.getenv("TMPDIR") orelse "/tmp", "/");
    const uid = lib_posix.getuid();

    const socket_dir: []const u8 = if (lib_posix.getenv("ZMX_DIR")) |zmxdir|
        try alloc.dupe(u8, zmxdir)
    else if (lib_posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime|
        try std.fmt.allocPrint(alloc, "{s}/zmx", .{xdg_runtime})
    else
        try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });

    return socket_dir;
}

fn logDir(alloc: std.mem.Allocator) ![]const u8 {
    const log_dir = if (lib_posix.getenv("ZMX_DIR")) |zmxdir|
        try std.fmt.allocPrint(alloc, "{s}/logs", .{zmxdir})
    else if (lib_posix.getenv("XDG_STATE_HOME")) |xdg_state_home|
        try std.fmt.allocPrint(alloc, "{s}/zmx/logs", .{xdg_state_home})
    else if (lib_posix.getenv("HOME")) |home_dir|
        try std.fmt.allocPrint(alloc, "{s}/.local/state/zmx/logs", .{home_dir})
    else fallback: {
        // This is the last resort: falling back to /tmp/$UID if HOME is unset.
        const tmpdir = std.mem.trimEnd(u8, lib_posix.getenv("TMPDIR") orelse "/tmp", "/");
        const uid = lib_posix.getuid();
        break :fallback try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });
    };

    return log_dir;
}

pub fn deinit(self: *Cfg, alloc: std.mem.Allocator) void {
    alloc.free(self.capabilities);
    if (self.socket_dir.len > 0) alloc.free(self.socket_dir);
    if (self.log_dir.len > 0) alloc.free(self.log_dir);
}

pub fn mkdir(self: *Cfg, io: std.Io) !void {
    const sock_perms = std.Io.Dir.Permissions.fromMode(@intCast(self.dir_mode));
    try mkdirAll(io, self.socket_dir, sock_perms);
    const log_perms = std.Io.Dir.Permissions.fromMode(@intCast(self.dir_mode));
    try mkdirAll(io, self.log_dir, log_perms);
}

fn mkdirAll(io: std.Io, sub_dir_path: []const u8, permissions: std.Io.Dir.Permissions) !void {
    var it = std.fs.path.componentIterator(sub_dir_path);
    var component = it.last() orelse return error.BadPathName;
    while (true) {
        std.Io.Dir.createDirAbsolute(io, component.path, permissions) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Dangling symlinks return PathAlreadyExists on mkdir but fail on traversal,
                // causing an infinite loop between previous() and next().
                const stat = std.Io.Dir.cwd().statFile(io, component.path, .{}) catch |e| switch (e) {
                    error.FileNotFound => return error.NotDir,
                    else => |stat_err| return stat_err,
                };
                if (stat.kind != .directory) return error.NotDir;
            },
            error.FileNotFound => |e| {
                component = it.previous() orelse return e;
                continue;
            },
            else => |e| return e,
        };
        component = it.next() orelse return;
    }
}

test "Cfg.init uses default modes when env vars are not set" {
    const alloc = std.testing.allocator;

    // Ensure they are not set
    _ = cross.unsetenv("ZMX_DIR_MODE");
    _ = cross.unsetenv("ZMX_LOG_MODE");

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o750), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o640), cfg.log_mode);
}

test "Cfg.init uses custom modes from env vars" {
    const alloc = std.testing.allocator;

    // Set custom octal values
    _ = cross.setenv("ZMX_DIR_MODE", "770", 1);
    _ = cross.setenv("ZMX_LOG_MODE", "660", 1);
    defer {
        _ = cross.unsetenv("ZMX_DIR_MODE");
        _ = cross.unsetenv("ZMX_LOG_MODE");
    }

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o770), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o660), cfg.log_mode);
}

test "mkdirAll fails on dangling symlink instead of looping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    // Dir.realPathFile is unsupported on OpenBSD, so build the absolute path
    // from the cwd instead.
    const cwd_path = try std.process.currentPathAlloc(std.testing.io, alloc);
    defer alloc.free(cwd_path);
    const tmp_path = try std.fs.path.join(alloc, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(tmp_path);

    try tmp.dir.symLink(std.testing.io, "nonexistent", "broken_link", .{});

    const target_path = try std.fs.path.join(alloc, &.{ tmp_path, "broken_link", "sub" });
    defer alloc.free(target_path);

    const perms = std.Io.Dir.Permissions.fromMode(0o750);
    try std.testing.expectError(error.NotDir, mkdirAll(std.testing.io, target_path, perms));
}

test "explicit optional definitions preserve required capabilities" {
    if (!has_daemon) {
        return error.SkipZigTest;
    }

    const included = @import("capabilities/definitions.zig");
    const definitions = [_]CapabilityDefinition{included.program_status};
    const alloc = std.testing.allocator;
    var required = try Cfg.initWithOptionalCapabilities(alloc, std.testing.io, &.{});
    defer required.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), required.capabilities.len);
    try std.testing.expectEqualStrings("osc7", required.capabilities[0].name);
    var custom = try Cfg.initWithOptionalCapabilities(alloc, std.testing.io, &definitions);
    defer custom.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), custom.capabilities.len);
    try std.testing.expectEqualStrings("osc7", custom.capabilities[0].name);
    try std.testing.expectEqualStrings("osc7501", custom.capabilities[1].name);
    try std.testing.expect(custom.capabilities.ptr != definitions[0..].ptr);
    const definition = included.program_status;
    try std.testing.expectError(error.DuplicateCapability, Cfg.initWithOptionalCapabilities(alloc, std.testing.io, &.{ definition, definition }));
}

test "default capability selection ignores the former environment setting" {
    if (!has_daemon) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    const previous = if (lib_posix.getenv("ZMX_CAPABILITIES")) |value| try alloc.dupeSentinel(u8, value, 0) else null;
    defer if (previous) |value| alloc.free(value);

    defer {
        if (previous) |value| {
            _ = cross.setenv("ZMX_CAPABILITIES", value, 1);
        } else {
            _ = cross.unsetenv("ZMX_CAPABILITIES");
        }
    }

    // Capability selection belongs to the caller. An inherited variable must
    // neither enable optional behavior nor make an otherwise valid call fail.
    for ([_][:0]const u8{ "osc7501", "missing" }) |value| {
        _ = cross.setenv("ZMX_CAPABILITIES", value, 1);
        var defaults = try Cfg.init(alloc, std.testing.io);
        defer defaults.deinit(alloc);

        try std.testing.expectEqual(@as(usize, 1), defaults.capabilities.len);
        try std.testing.expectEqualStrings("osc7", defaults.capabilities[0].name);
    }
}
