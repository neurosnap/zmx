const std = @import("std");
const Cfg = @import("../cfg.zig").Cfg;
const shared = @import("shared.zig");
const ipc = @import("../ipc.zig");

pub fn send(cfg: *Cfg, session_name: []const u8, socket_path: []const u8, text_parts: [][]const u8, tag: ipc.Tag) !void {
    const alloc = std.heap.c_allocator;

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(alloc);

    if (text_parts.len > 0) {
        for (text_parts, 0..) |part, i| {
            if (i > 0) try payload.append(alloc, ' ');
            try payload.appendSlice(alloc, part);
        }
    } else {
        const stdin_fd = std.posix.STDIN_FILENO;
        if (!std.posix.isatty(stdin_fd)) {
            while (true) {
                var tmp: [shared.io_buf_size]u8 = undefined;
                const n = std.posix.read(stdin_fd, &tmp) catch |err| {
                    if (err == error.WouldBlock) break;
                    return err;
                };
                if (n == 0) break;
                try payload.appendSlice(alloc, tmp[0..n]);
            }
            if (tag != .Output and payload.items.len > 0 and payload.items[payload.items.len - 1] == '\n') {
                _ = payload.pop();
            }
        }
    }

    if (payload.items.len == 0) return error.TextRequired;

    const probe_result = shared.probeSessionChecked(alloc, cfg.socket_dir, session_name, socket_path) catch {
        try shared.printOut("session {s} is unresponsive\ndaemon may be busy: try again\n", .{session_name});
        return;
    };
    defer std.posix.close(probe_result.fd);

    ipc.send(probe_result.fd, tag, payload.items) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };
}
