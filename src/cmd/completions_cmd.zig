const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const completions = @import("../completions.zig");
const cmdDefType = @import("root.zig").CmdDef;
const shared = @import("shared.zig");

fn printCompletions(shell: completions.Shell, all_commands: []const cmdDefType) !void {
    try shared.printOut("{s}", .{switch (shell) {
        .bash => completions.bashScript(all_commands),
        .zsh => completions.zshScript(all_commands),
        .fish => completions.fishScript(all_commands),
        .nu => completions.nuScript(all_commands),
    }});
}

pub fn cmdCompletions(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator, all_commands: []const cmdDefType) !void {
    _ = alloc;
    _ = cfg;
    const arg = args.next() orelse return;
    if (shared.isHelp(arg)) return shared.printUsage("completions", "<shell>");
    const shell = completions.Shell.fromString(arg) orelse return;
    return printCompletions(shell, all_commands);
}
