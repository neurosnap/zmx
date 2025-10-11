const std = @import("std");
const toml = @import("toml");

pub const Config = struct {
    socket_path: []const u8 = "/tmp/zmx.sock",

    pub fn load(allocator: std.mem.Allocator) !Config {
        const config_path = getConfigPath(allocator) catch |err| {
            if (err == error.FileNotFound) {
                return Config{};
            }
            return err;
        };
        defer allocator.free(config_path);

        var parser = toml.Parser(Config).init(allocator);
        defer parser.deinit();

        var result = parser.parseFile(config_path) catch |err| {
            if (err == error.FileNotFound) {
                return Config{};
            }
            return err;
        };
        defer result.deinit();

        const config = Config{
            .socket_path = try allocator.dupe(u8, result.value.socket_path),
        };
        return config;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (!std.mem.eql(u8, self.socket_path, "/tmp/zmx.sock")) {
            allocator.free(self.socket_path);
        }
    }
};

fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.FileNotFound;
    const xdg_config_home = std.posix.getenv("XDG_CONFIG_HOME");

    if (xdg_config_home) |config_home| {
        return try std.fs.path.join(allocator, &.{ config_home, "zmx", "config.toml" });
    } else {
        return try std.fs.path.join(allocator, &.{ home, ".config", "zmx", "config.toml" });
    }
}
