const std = @import("std");
const clap = @import("clap");
const posix = std.posix;

pub const version = "0.1.0";

const SubCommands = enum {
    help,
    daemon,
    list,
    attach,
    detach,
    kill,
};

const main_parsers = .{
    .command = clap.parsers.enumeration(SubCommands),
};

// The parameters for `main`. Parameters for the subcommands are specified further down.
const main_params = clap.parseParamsComptime(
    \\-h, --help            Display this help message and exit
    \\-v, --version         Display version information and exit
    \\<command>
    \\
);

// To pass around arguments returned by clap, `clap.Result` and `clap.ResultEx` can be used to
// get the return type of `clap.parse` and `clap.parseEx`.
const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

pub fn help() !void {
    const help_text =
        \\Usage: zmx <command>
        \\
        \\Commands:
        \\  help       Show this help message
        \\  daemon     Start the zmx daemon
        \\  attach     Attach to a session
        \\  detach     Detach from a session
        \\  kill       Kill a session
        \\  list       List all sessions
        \\
        \\Options:
        \\
    ;
    _ = try posix.write(posix.STDOUT_FILENO, help_text);

    var buf: [1024]u8 = undefined;
    var stdout_file = std.fs.File{ .handle = posix.STDOUT_FILENO };
    var writer = stdout_file.writer(&buf);
    try clap.help(&writer.interface, clap.Help, &main_params, .{});
    try writer.interface.flush();
}

pub fn parse(gpa: std.mem.Allocator, iter: *std.process.ArgIterator) !MainArgs {
    _ = iter.next();

    var diag = clap.Diagnostic{};
    const res = clap.parseEx(clap.Help, &main_params, main_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,

        // Terminate the parsing of arguments after parsing the first positional (0 is passed
        // here because parsed positionals are, like slices and arrays, indexed starting at 0).
        //
        // This will terminate the parsing after parsing the subcommand enum and leave `iter`
        // not fully consumed. It can then be reused to parse the arguments for subcommands.
        .terminating_positional = 0,
    }) catch |err| {
        return err;
    };

    return res;
}
