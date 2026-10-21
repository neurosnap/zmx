//! Example: list active zmx sessions and print their details.
const std = @import("std");
const zmx = @import("zmx");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const sessions = try zmx.list(gpa, io);
    defer {
        for (sessions) |s| s.deinit(gpa);
        gpa.free(sessions);
    }

    if (sessions.len == 0) {
        std.debug.print("no active sessions\n", .{});
        return;
    }

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    for (sessions) |s| {
        try w.interface.print("{s}\t", .{s.name});
        if (s.pid) |pid| try w.interface.print("pid={d}\t", .{pid});
        if (s.is_error) try w.interface.print("[error]\t", .{});
        if (s.task_exit_code) |code| try w.interface.print("exit={d}\t", .{code});
        if (s.labels) |labels| try w.interface.print("{s}\t", .{labels});
        try w.interface.print("\n", .{});
    }
}
