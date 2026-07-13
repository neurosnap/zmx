const std = @import("std");
const Cfg = @import("../Cfg.zig").Cfg;
const shared = @import("shared.zig");
const util = @import("../util.zig");

const cmd_list = @import("list.zig");
const cmd_detach = @import("detach.zig");
const cmd_kill = @import("kill.zig");
const cmd_history = @import("history.zig");
const cmd_wait = @import("wait.zig");
const cmd_send = @import("send.zig");
const cmd_print = @import("send.zig");
const cmd_tail = @import("tail.zig");
const cmd_attach = @import("attach.zig");
const cmd_run = @import("run.zig");
const cmd_write = @import("write.zig");
const cmd_version = @import("version.zig");
const cmd_help = @import("help.zig");
const completions = @import("../completions.zig");

pub const isHelp = shared.isHelp;
pub const printUsage = shared.printUsage;

pub const FlagDef = struct {
    name: []const u8,
    description: []const u8,
};

pub const ArgCompletion = enum {
    sessions,
    shells,
    none,
};

pub const CmdDef = struct {
    name: []const u8,
    aliases: []const []const u8,
    help_line: []const u8,
    run: *const fn (std.mem.Allocator, *Cfg, *std.process.ArgIterator) anyerror!void,
    next_arg: ArgCompletion,
    flags: []const FlagDef,
};

pub fn helpWrapper(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    try cmd_help.cmdHelp(alloc, cfg, args, ALL_COMMANDS);
}

fn completionsWrapper(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    _ = alloc;
    _ = cfg;
    const arg = args.next() orelse return;
    if (shared.isHelp(arg)) return shared.printUsage("completions", "<shell>");
    const shell = completions.Shell.fromString(arg) orelse return;
    try shared.printOut("{s}", .{switch (shell) {
        .bash => completions.bashScript(ALL_COMMANDS),
        .zsh => completions.zshScript(ALL_COMMANDS),
        .fish => completions.fishScript(ALL_COMMANDS),
        .nu => completions.nuScript(ALL_COMMANDS),
    }});
}

pub const ALL_COMMANDS: []const CmdDef = &[_]CmdDef{
    .{
        .name = "attach",
        .aliases = &.{"a"},
        .help_line = "<name> [command...]  Attach to session, creating if needed",
        .run = cmd_attach.cmdAttach,
        .next_arg = .sessions,
        .flags = &.{},
    },
    .{
        .name = "run",
        .aliases = &.{"r"},
        .help_line = "<name> [-d] [command...]  Send command without attaching",
        .run = cmd_run.cmdRun,
        .next_arg = .sessions,
        .flags = &.{.{ .name = "-d", .description = "Detach from the calling terminal" }},
    },
    .{
        .name = "send",
        .aliases = &.{"s"},
        .help_line = "<name> <text...>  Send raw input to session PTY",
        .run = cmd_send.cmdSend,
        .next_arg = .sessions,
        .flags = &.{},
    },
    .{
        .name = "print",
        .aliases = &.{"p"},
        .help_line = "<name> <text...>  Inject text into session display",
        .run = cmd_print.cmdPrint,
        .next_arg = .sessions,
        .flags = &.{},
    },
    .{
        .name = "write",
        .aliases = &.{"wr"},
        .help_line = "<name> <file_path>  Write stdin to file_path through the session",
        .run = cmd_write.cmdWrite,
        .next_arg = .sessions,
        .flags = &.{},
    },
    .{
        .name = "detach",
        .aliases = &.{"d"},
        .help_line = "Detach all clients (ctrl+\\ for current client)",
        .run = cmd_detach.cmdDetach,
        .next_arg = .none,
        .flags = &.{},
    },
    .{
        .name = "list",
        .aliases = &.{ "l", "ls" },
        .help_line = "[--short]  List active sessions",
        .run = cmd_list.cmdList,
        .next_arg = .none,
        .flags = &.{.{ .name = "--short", .description = "Short output: session names only" }},
    },
    .{
        .name = "kill",
        .aliases = &.{"k"},
        .help_line = "<name>... [--force]  Kill session and all attached clients",
        .run = cmd_kill.cmdKill,
        .next_arg = .sessions,
        .flags = &.{.{ .name = "--force", .description = "Force kill" }},
    },
    .{
        .name = "history",
        .aliases = &.{"hi"},
        .help_line = "<name> [--vt|--html]  Output session scrollback",
        .run = cmd_history.cmdHistory,
        .next_arg = .sessions,
        .flags = &.{
            .{ .name = "--vt", .description = "VT escape sequence format" },
            .{ .name = "--html", .description = "HTML format" },
        },
    },
    .{
        .name = "wait",
        .aliases = &.{"w"},
        .help_line = "<name>...  Wait for session tasks to complete",
        .run = cmd_wait.cmdWait,
        .next_arg = .sessions,
        .flags = &.{},
    },
    .{
        .name = "tail",
        .aliases = &.{"t"},
        .help_line = "<name>...  Follow session output",
        .run = cmd_tail.cmdTail,
        .next_arg = .sessions,
        .flags = &.{},
    },
    .{
        .name = "completions",
        .aliases = &.{"c"},
        .help_line = "<shell>  Shell completions (bash, zsh, fish, nu)",
        .run = completionsWrapper,
        .next_arg = .shells,
        .flags = &.{},
    },
    .{
        .name = "version",
        .aliases = &.{ "v", "-v", "--version" },
        .help_line = "Show version and metadata",
        .run = cmd_version.cmdVersion,
        .next_arg = .none,
        .flags = &.{},
    },
    .{
        .name = "help",
        .aliases = &.{ "h", "-h" },
        .help_line = "Show this help",
        .run = helpWrapper,
        .next_arg = .none,
        .flags = &.{},
    },
};

pub const Command = enum {
    attach,
    run,
    send,
    print,
    write,
    detach,
    list,
    kill,
    history,
    wait,
    tail,
    completions,
    version,
    help,

    pub fn fromName(name: []const u8) ?Command {
        inline for (std.meta.fields(Command)) |field| {
            const cmd: Command = @enumFromInt(field.value);
            const meta = ALL_COMMANDS[@intFromEnum(cmd)];
            if (std.mem.eql(u8, meta.name, name)) return cmd;
            for (meta.aliases) |alias| {
                if (std.mem.eql(u8, alias, name)) return cmd;
            }
        }
        return null;
    }
};

pub const SessionMatch = struct {
    name: []const u8,
    is_prefix: bool,

    pub fn matches(self: SessionMatch, name: []const u8) bool {
        if (self.is_prefix) return std.mem.startsWith(u8, name, self.name);
        return std.mem.eql(u8, self.name, name);
    }
};

pub fn parseSessionArg(alloc: std.mem.Allocator, arg: []const u8) !SessionMatch {
    if (arg.len > 0 and arg[arg.len - 1] == '*') {
        return .{ .name = try alloc.dupe(u8, arg[0 .. arg.len - 1]), .is_prefix = true };
    }
    return .{ .name = try alloc.dupe(u8, arg), .is_prefix = false };
}

pub fn collectMatchingSessions(alloc: std.mem.Allocator, sessions: []util.SessionEntry, matchers: []const SessionMatch) ![][]const u8 {
    var matched: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (matched.items) |name| alloc.free(name);
        matched.deinit(alloc);
    }
    for (sessions) |session| {
        for (matchers) |m| {
            if (!m.matches(session.name)) continue;
            try matched.append(alloc, try alloc.dupe(u8, session.name));
            break;
        }
    }
    for (matchers) |m| {
        if (m.is_prefix) continue;
        try matched.append(alloc, try alloc.dupe(u8, m.name));
    }
    return try matched.toOwnedSlice(alloc);
}
