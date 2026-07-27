const std = @import("std");

pub var log_system = LogSystem{};

pub fn zmxLogFn(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime format: []const u8,
    args: anytype,
) void {
    log_system.log(level, scope, format, args) catch {};
}

pub const LogSystem = struct {
    file: ?std.Io.File = null,
    mutex: std.Io.Mutex = .init,
    current_size: u64 = 0,
    max_size: u64 = 2 * 1024 * 1024, // 2MB
    path: []const u8 = "",
    io: std.Io = undefined,
    mode: std.Io.File.Permissions = std.Io.File.Permissions.fromMode(0o640),

    pub fn init(self: *LogSystem, io: std.Io, path: []const u8, mode: std.Io.File.Permissions) !void {
        self.io = io;
        self.path = path;
        self.mode = mode;

        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.createFileAbsolute(
                self.io,
                path,
                .{ .read = true, .permissions = self.mode },
            ),
            else => return err,
        };

        const end_pos = try std.Io.File.length(file, self.io);
        var buf: [1]u8 = undefined;
        var w = std.Io.File.writer(file, self.io, &buf);
        try w.seekTo(end_pos);
        self.current_size = end_pos;
        self.file = file;
    }

    pub fn deinit(self: *LogSystem) void {
        if (self.file) |f| std.Io.File.close(f, self.io);
    }

    pub fn log(
        self: *LogSystem,
        comptime level: std.log.Level,
        comptime scope: anytype,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.file == null) {
            std.log.defaultLog(level, scope, format, args);
            return;
        }

        if (self.current_size >= self.max_size) {
            self.wipe() catch |err| {
                std.debug.print("Log wipe failed: {s}\n", .{@errorName(err)});
            };
        }

        const now: std.Io.Timestamp = .now(self.io, .real);
        const prefix = "[{d}] [{s}] ({s}): ";
        const scope_name = @tagName(scope);
        const level_name = level.asText();

        const prefix_args = .{
            now,
            level_name,
            scope_name,
        };

        if (self.file) |f| {
            const prefix_len = std.fmt.count(prefix, prefix_args);
            const msg_len = std.fmt.count(format, args);
            const newline_len = 1;
            const total_len = prefix_len + msg_len + newline_len;
            self.current_size += total_len;

            var buf: [4096]u8 = undefined;
            var w = f.writerStreaming(self.io, &buf);
            std.Io.Writer.print(&w.interface, prefix ++ format ++ "\n", prefix_args ++ args) catch {};
            w.interface.flush() catch {};
        }
    }

    fn wipe(self: *LogSystem) !void {
        if (self.file) |f| {
            std.Io.File.close(f, self.io);
            self.file = null;
        }

        self.file = try std.Io.Dir.createFileAbsolute(
            self.io,
            self.path,
            .{
                .truncate = true,
                .read = true,
                .permissions = self.mode,
            },
        );
        self.current_size = 0;
    }
};
