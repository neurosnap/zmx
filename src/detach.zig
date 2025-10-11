const std = @import("std");
const posix = std.posix;

const socket_path = "/tmp/zmx.sock";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Find the client_fd file in home directory
    const home_dir = posix.getenv("HOME") orelse "/tmp";

    var session_name: ?[]const u8 = null;
    var client_fd: ?i64 = null;

    // Look for .zmx_client_fd_* files
    var dir = std.fs.cwd().openDir(home_dir, .{ .iterate = true }) catch {
        std.debug.print("Error: Cannot access home directory\n", .{});
        std.process.exit(1);
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, ".zmx_client_fd_")) continue;

        // Extract session name from filename
        const name_start = ".zmx_client_fd_".len;
        session_name = try allocator.dupe(u8, entry.name[name_start..]);

        // Read the client_fd from the file
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, entry.name });
        defer allocator.free(full_path);

        if (std.fs.cwd().openFile(full_path, .{})) |file| {
            defer file.close();
            var buf: [32]u8 = undefined;
            const bytes_read = file.readAll(&buf) catch 0;
            if (bytes_read > 0) {
                const fd_str = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);
                client_fd = std.fmt.parseInt(i64, fd_str, 10) catch null;
            }
        } else |_| {}

        break; // Found one, use it
    }

    if (session_name == null) {
        std.debug.print("Error: Not currently attached to any session\n", .{});
        std.debug.print("Use Ctrl-b d to detach from within an attached session\n", .{});
        std.process.exit(1);
    }
    defer if (session_name) |name| allocator.free(name);

    const unix_addr = try std.net.Address.initUnix(socket_path);
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(socket_fd);

    posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen()) catch |err| {
        if (err == error.ConnectionRefused) {
            std.debug.print("Error: Unable to connect to zmx daemon at {s}\nPlease start the daemon first with: zmx daemon\n", .{socket_path});
            std.process.exit(1);
        }
        return err;
    };

    const request = if (client_fd) |fd|
        try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"detach_session_request\",\"payload\":{{\"session_name\":\"{s}\",\"client_fd\":{d}}}}}\n",
            .{ session_name.?, fd },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"detach_session_request\",\"payload\":{{\"session_name\":\"{s}\"}}}}\n",
            .{session_name.?},
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
        std.debug.print("Detached from session: {s}\n", .{session_name.?});
    } else {
        const error_msg = payload.get("error_message").?.string;
        std.debug.print("Failed to detach: {s}\n", .{error_msg});
        std.process.exit(1);
    }
}
