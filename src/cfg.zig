const std = @import("std");
const posix = std.posix;

pub const Cfg = struct {
    socket_dir: []const u8,
    log_dir: []const u8,
    max_scrollback: usize = 10_000_000,
    dir_mode: u32 = 0o750,
    log_mode: u32 = 0o640,

    pub fn init(alloc: std.mem.Allocator) !Cfg {
        const socket_dir = try socketDir(alloc);
        const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{socket_dir});
        errdefer alloc.free(log_dir);

        const dir_mode = if (std.posix.getenv("NMUX_DIR_MODE")) |m|
            std.fmt.parseInt(u32, m, 8) catch 0o750
        else
            0o750;

        const log_mode = if (std.posix.getenv("NMUX_LOG_MODE")) |m|
            std.fmt.parseInt(u32, m, 8) catch 0o640
        else
            0o640;

        var cfg = Cfg{
            .socket_dir = socket_dir,
            .log_dir = log_dir,
            .dir_mode = dir_mode,
            .log_mode = log_mode,
        };

        try cfg.mkdir();

        return cfg;
    }

    fn socketDir(alloc: std.mem.Allocator) ![]const u8 {
        const tmpdir = std.mem.trimRight(u8, posix.getenv("TMPDIR") orelse "/tmp", "/");
        const uid = posix.getuid();

        const socket_dir: []const u8 = if (posix.getenv("NMUX_DIR")) |nmuxdir|
            try alloc.dupe(u8, nmuxdir)
        else if (posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime|
            try std.fmt.allocPrint(alloc, "{s}/nmux", .{xdg_runtime})
        else
            try std.fmt.allocPrint(alloc, "{s}/nmux-{d}", .{ tmpdir, uid });
        errdefer alloc.free(socket_dir);

        return socket_dir;
    }

    pub fn deinit(self: *Cfg, alloc: std.mem.Allocator) void {
        if (self.socket_dir.len > 0) alloc.free(self.socket_dir);
        if (self.log_dir.len > 0) alloc.free(self.log_dir);
    }

    pub fn mkdir(self: *Cfg) !void {
        posix.mkdirat(
            posix.AT.FDCWD,
            self.socket_dir,
            @intCast(self.dir_mode),
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        posix.mkdirat(
            posix.AT.FDCWD,
            self.log_dir,
            @intCast(self.dir_mode),
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
};

test "Cfg.init uses default modes when env vars are not set" {
    const cross = @import("cross.zig");
    const alloc = std.testing.allocator;

    _ = cross.c.unsetenv("NMUX_DIR_MODE");
    _ = cross.c.unsetenv("NMUX_LOG_MODE");

    var cfg = try Cfg.init(alloc);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o750), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o640), cfg.log_mode);
}

test "Cfg.init uses custom modes from env vars" {
    const cross = @import("cross.zig");
    const alloc = std.testing.allocator;

    _ = cross.c.setenv("NMUX_DIR_MODE", "770", 1);
    _ = cross.c.setenv("NMUX_LOG_MODE", "660", 1);
    defer {
        _ = cross.c.unsetenv("NMUX_DIR_MODE");
        _ = cross.c.unsetenv("NMUX_LOG_MODE");
    }

    var cfg = try Cfg.init(alloc);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o770), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o660), cfg.log_mode);
}
