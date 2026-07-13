const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const build_options = @import("build_options");

pub fn cmdVersion(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    _ = alloc;
    _ = args;
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("zmx\t\t{s}\nghostty_vt\t{s}\nsocket_dir\t{s}\nlog_dir\t\t{s}\n", .{ build_options.version, build_options.ghostty_version, cfg.socket_dir, cfg.log_dir });
    try w.interface.flush();
}
