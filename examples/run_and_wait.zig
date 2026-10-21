//! Example: run a command in a zmx session, stream its output, then read the
//! scrollback and clean up.
const std = @import("std");
const zmx = @import("zmx");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Run `echo "hello from libzmx"` in a task-mode session.
    // With detached = false, output is streamed to stdout while it runs.
    const exit_code = try zmx.run(
        gpa,
        io,
        "example-run",
        &.{ "echo", "hello from libzmx" },
        .{},
    );

    // Read the full scrollback of the session.
    const scrollback = try zmx.history(gpa, io, "example-run", .plain);
    defer gpa.free(scrollback);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("exit code: {d}\n--- scrollback ---\n", .{exit_code});
    try w.interface.writeAll(scrollback);
    try w.interface.flush();

    // Clean up the session.
    _ = try zmx.kill(gpa, io, "example-run", .{});
}
