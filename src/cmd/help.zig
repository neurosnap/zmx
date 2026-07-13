const std = @import("std");
const Cfg = @import("../cfg.zig").Cfg;
const shared = @import("shared.zig");
const cmdDefType = @import("root.zig").CmdDef;

pub fn cmdHelp(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator, all_commands: []const cmdDefType) !void {
    _ = alloc;
    _ = cfg;
    _ = args;
    try shared.printOut("nmux - session persistence for terminal processes\n\nUsage: nmux <command> [args...]\n\nCommands:\n", .{});
    for (all_commands) |m| {
        const display_name = if (std.mem.startsWith(u8, m.name, m.aliases[0])) m.name[m.aliases[0].len..] else m.name;
        try shared.printOut("  [{s}]{s}", .{ m.aliases[0], display_name });
        for (m.aliases[1..]) |alias| {
            if (std.mem.startsWith(u8, alias, "-")) continue;
            try shared.printOut("|{s}", .{alias});
        }
        try shared.printOut("  {s}\n", .{m.help_line});
    }
    try shared.printOut(
        \\Environment variables:
        \\  SHELL                Default shell for new sessions
        \\  NMUX_DIR              Socket directory (priority 1)
        \\  XDG_RUNTIME_DIR      Socket directory (priority 2)
        \\  TMPDIR               Socket directory (priority 3)
        \\  NMUX_SESSION          Session name (injected automatically)
        \\  NMUX_SESSION_PREFIX   Prefix added to all session names
        \\  NMUX_DIR_MODE         Sets mode for socket and log directories (octal, defaults to 0750)
        \\  NMUX_LOG_MODE         Sets mode for log files (octal, defaults to 0640)
    , .{});
}
