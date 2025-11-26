const std = @import("std");

pub const LogSystem = struct {
    file: ?std.fs.File = null,
    mutex: std.Thread.Mutex = .{},
    current_size: u64 = 0,
    max_size: u64 = 5 * 1024 * 1024, // 5MB
    path: []const u8 = "",
    alloc: std.mem.Allocator = undefined,

    pub fn init(self: *LogSystem, alloc: std.mem.Allocator, path: []const u8) !void {
        self.alloc = alloc;
        self.path = try alloc.dupe(u8, path);

        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.createFileAbsolute(path, .{ .read = true }),
            else => return err,
        };

        const end_pos = try file.getEndPos();
        try file.seekTo(end_pos);
        self.current_size = end_pos;
        self.file = file;
    }

    pub fn deinit(self: *LogSystem) void {
        if (self.file) |f| f.close();
        if (self.path.len > 0) self.alloc.free(self.path);
    }

    pub fn log(self: *LogSystem, comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.file == null) {
            std.log.defaultLog(level, scope, format, args);
            return;
        }

        if (self.current_size >= self.max_size) {
            self.rotate() catch |err| {
                std.debug.print("Log rotation failed: {s}\n", .{@errorName(err)});
            };
        }

        const now = std.time.milliTimestamp();
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
            var w = f.writerStreaming(&buf);
            w.interface.print(prefix ++ format ++ "\n", prefix_args ++ args) catch {};
            w.interface.flush() catch {};
        }
    }

    fn rotate(self: *LogSystem) !void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }

        const old_path = try std.fmt.allocPrint(self.alloc, "{s}.old", .{self.path});
        defer self.alloc.free(old_path);

        std.fs.renameAbsolute(self.path, old_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        self.file = try std.fs.createFileAbsolute(self.path, .{ .truncate = true, .read = true });
        self.current_size = 0;
    }
};
