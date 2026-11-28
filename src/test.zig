const std = @import("std");

comptime {
    _ = @import("main.zig");
    _ = @import("util.zig");
    _ = @import("socket.zig");
    _ = @import("ipc.zig");
    _ = @import("label.zig");
    _ = @import("signal.zig");
    _ = @import("loop.zig");
    _ = @import("terminal.zig");
    _ = @import("osc/osc7.zig");
    _ = @import("cfg.zig");
    _ = @import("daemonize.zig");
    _ = @import("client.zig");
}

test {
    std.testing.refAllDecls(@import("lib.zig"));
}
