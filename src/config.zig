const Config = @This();
socket_path: []const u8 = "/tmp/zmx.sock",
detach_prefix: u8 = 0x02, // Ctrl+B (like tmux)
detach_key: u8 = 'd',

session_name: []const u8 = "",

pub fn init(sp: ?[]const u8) *Config {
    var cfg = Config{};
    if (sp) |path| {
        cfg.socket_path = path;
    }
    return &cfg;
}
