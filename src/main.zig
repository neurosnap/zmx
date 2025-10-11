const std = @import("std");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const daemon = @import("daemon.zig");
const attach = @import("attach.zig");
const detach = @import("detach.zig");
const kill = @import("kill.zig");
const list = @import("list.zig");
const clap = @import("clap");

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

    var config = try config_mod.Config.load(allocator);
    defer config.deinit(allocator);

    switch (command) {
        .help => try cli.help(),
        .daemon => try daemon.main(config, &iter),
        .list => try list.main(config, &iter),
        .attach => try attach.main(config, &iter),
        .detach => try detach.main(config, &iter),
        .kill => try kill.main(config, &iter),
    }
}
