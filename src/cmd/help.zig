const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const cmdDefType = @import("root.zig").CmdDef;

pub fn cmdHelp(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator, all_commands: []const cmdDefType) !void {
    _ = alloc;
    _ = cfg;
    _ = args;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("zmx - session persistence for terminal processes\n\nUsage: zmx <command> [args...]\n\nCommands:\n", .{});
    for (all_commands) |m| {
        const display_name = if (std.mem.startsWith(u8, m.name, m.aliases[0])) m.name[m.aliases[0].len..] else m.name;
        try w.interface.print("  [{s}]{s}", .{ m.aliases[0], display_name });
        for (m.aliases[1..]) |alias| {
            if (std.mem.startsWith(u8, alias, "-")) continue;
            try w.interface.print("|{s}", .{alias});
        }
        try w.interface.print("  {s}\n", .{m.help_line});
    }
    try w.interface.print(
        \\Environment variables:
        \\  SHELL                Default shell for new sessions
        \\  ZMX_DIR              Socket directory (priority 1)
        \\  XDG_RUNTIME_DIR      Socket directory (priority 2)
        \\  TMPDIR               Socket directory (priority 3)
        \\  ZMX_SESSION          Session name (injected automatically)
        \\  ZMX_SESSION_PREFIX   Prefix added to all session names
        \\  ZMX_DIR_MODE         Sets mode for socket and log directories (octal, defaults to 0750)
        \\  ZMX_LOG_MODE         Sets mode for log files (octal, defaults to 0640)
    , .{});
    try w.interface.flush();
}
