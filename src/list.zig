const std = @import("std");
const posix = std.posix;

const socket_path = "/tmp/zmx.sock";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const unix_addr = try std.net.Address.initUnix(socket_path);
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(socket_fd);

    try posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen());

    const request = "{\"type\":\"list_sessions_request\",\"payload\":{}}\n";
    _ = try posix.write(socket_fd, request);

    var buffer: [8192]u8 = undefined;
    const bytes_read = try posix.read(socket_fd, &buffer);

    if (bytes_read == 0) {
        std.debug.print("No response from daemon\n", .{});
        return;
    }

    const response = buffer[0..bytes_read];
    const newline_idx = std.mem.indexOf(u8, response, "\n") orelse bytes_read;
    const msg_line = response[0..newline_idx];

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        msg_line,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value.object;
    const payload = root.get("payload").?.object;
    const status = payload.get("status").?.string;

    if (!std.mem.eql(u8, status, "ok")) {
        const error_msg = payload.get("error_message").?.string;
        std.debug.print("Error: {s}\n", .{error_msg});
        return;
    }

    const sessions = payload.get("sessions").?.array;

    if (sessions.items.len == 0) {
        std.debug.print("No active sessions\n", .{});
        return;
    }

    std.debug.print("Active sessions:\n", .{});
    std.debug.print("{s:<20} {s:<12} {s:<8} {s}\n", .{ "NAME", "STATUS", "CLIENTS", "CREATED" });
    std.debug.print("{s}\n", .{"-" ** 60});

    for (sessions.items) |session_value| {
        const session = session_value.object;
        const name = session.get("name").?.string;
        const session_status = session.get("status").?.string;
        const clients = session.get("clients").?.integer;
        const created_at = session.get("created_at").?.string;

        std.debug.print("{s:<20} {s:<12} {d:<8} {s}\n", .{ name, session_status, clients, created_at });
    }
}
