const std = @import("std");
const build_options = @import("build_options");
const CfgMod = @import("Cfg.zig");
const cmd = @import("cmd/root.zig");
const shared = @import("cmd/shared.zig");

const Cfg = CfgMod.Cfg;

pub const version = build_options.version;
pub const ghostty_version = build_options.ghostty_version;

pub const std_options: std.Options = .{
    .logFn = zmxLogFn,
    .log_level = .debug,
};

fn zmxLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    shared.log_system.log(level, scope, format, args);
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    shared.ignoreSigpipe();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.skip();

    var cfg = try Cfg.init(alloc);
    defer cfg.deinit(alloc);

    const log_path = try std.fs.path.join(alloc, &.{ cfg.log_dir, "zmx.log" });
    defer alloc.free(log_path);
    try shared.log_system.init(alloc, log_path, cfg.log_mode);
    defer shared.log_system.deinit();

    const raw = args.next() orelse "list";
    const cmd_enum = cmd.Command.fromName(raw) orelse {
        try cmd.helpWrapper(alloc, &cfg, &args);
        return;
    };

    try cmd.ALL_COMMANDS[@intFromEnum(cmd_enum)].run(alloc, &cfg, &args);
}
