const std = @import("std");
const cli = @import("cli.zig");
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

    const command = res.positionals[0] orelse {
        try cli.help();
        return;
    };

    switch (command) {
        .help => try cli.help(),
        .daemon => try daemon.main(),
        .list => try list.main(),
        .attach => try attach.main(),
        .detach => try detach.main(),
        .kill => try kill.main(),
    }
}
