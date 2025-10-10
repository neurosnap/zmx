const std = @import("std");
const posix = std.posix;

const socket_path = "/tmp/zmx.sock";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: zmx kill <session-name>\n", .{});
        std.process.exit(1);
    }

    const session_name = args[2];

    const unix_addr = try std.net.Address.initUnix(socket_path);
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(socket_fd);

    try posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen());

    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"kill_session_request\",\"payload\":{{\"session_name\":\"{s}\"}}}}\n",
        .{session_name},
    );
    defer allocator.free(request);

    _ = try posix.write(socket_fd, request);

    var buffer: [4096]u8 = undefined;
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

    if (std.mem.eql(u8, status, "ok")) {
        std.debug.print("Killed session: {s}\n", .{session_name});
    } else {
        const error_msg = payload.get("error_message").?.string;
        std.debug.print("Failed to kill session: {s}\n", .{error_msg});
        std.process.exit(1);
    }
}
