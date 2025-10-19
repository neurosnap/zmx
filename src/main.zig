const std = @import("std");
const clap = @import("clap");
const cli = @import("cli.zig");
const daemon = @import("daemon.zig");
const attach = @import("attach.zig");
const Config = @import("config.zig");

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();

    var res = try cli.parse(allocator, &iter);
    defer res.deinit();

    if (res.args.version != 0) {
        const version_text = "zmx " ++ cli.version ++ "\n";
        _ = try std.posix.write(std.posix.STDOUT_FILENO, version_text);
        return;
    }

    const command = res.positionals[0] orelse {
        try cli.help();
        return;
    };

    switch (command) {
        .help => try cli.help(),
        .daemon => try daemonCli(allocator),
        .attach => try attachCli(allocator),
    }
}

fn daemonCli(alloc: std.mem.Allocator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-s, --socket-path <str>  Path to the Unix socket file
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    const socket_path = res.args.@"socket-path";
    const cfg = Config.init(socket_path);
    try daemon.main(cfg);
}

fn attachCli(alloc: std.mem.Allocator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-s, --socket-path <str>  Path to the Unix socket file
        \\<str>
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    const socket_path = res.args.@"socket-path";

    const session_name = res.positionals[0] orelse {
        std.debug.print("Usage: zmx attach <session-name>\n", .{});
        return error.MissingSessionName;
    };

    const cfg = Config.init(socket_path);
    cfg.session_name = session_name;
    try attach.main(cfg);
}

test {}
