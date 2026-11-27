comptime {
    _ = @import("capability-api");
    _ = @import("capabilities/registry.zig");
    _ = @import("capabilities/program_status/main.zig");
    _ = @import("main.zig");
    _ = @import("util.zig");
    _ = @import("socket.zig");
    _ = @import("ipc.zig");
    _ = @import("label.zig");
    _ = @import("signal.zig");
    _ = @import("loop.zig");
    _ = @import("terminal.zig");
    _ = @import("cfg.zig");
    _ = @import("daemonize.zig");
    _ = @import("lib.zig");
    _ = @import("client.zig");
}
