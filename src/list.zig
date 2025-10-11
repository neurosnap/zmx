const std = @import("std");
const posix = std.posix;
const clap = @import("clap");
const config_mod = @import("config.zig");
const protocol = @import("protocol.zig");

const params = clap.parseParamsComptime(
    \\-s, --socket-path <str>  Path to the Unix socket file
    \\
);

pub fn main(config: config_mod.Config, iter: *std.process.ArgIterator) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        var buf: [1024]u8 = undefined;
        var stderr_file = std.fs.File{ .handle = posix.STDERR_FILENO };
        var writer = stderr_file.writer(&buf);
        diag.report(&writer.interface, err) catch {};
        writer.interface.flush() catch {};
        return err;
    };
    defer res.deinit();

    const socket_path = res.args.@"socket-path" orelse config.socket_path;

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

    try protocol.writeJson(allocator, socket_fd, .list_sessions_request, protocol.ListSessionsRequest{});

    var buffer: [8192]u8 = undefined;
    const bytes_read = try posix.read(socket_fd, &buffer);

    if (bytes_read == 0) {
        std.debug.print("No response from daemon\n", .{});
        return;
    }

    const response = buffer[0..bytes_read];
    const newline_idx = std.mem.indexOf(u8, response, "\n") orelse bytes_read;
    const msg_line = response[0..newline_idx];

    const parsed = try protocol.parseMessage(protocol.ListSessionsResponse, allocator, msg_line);
    defer parsed.deinit();

    const payload = parsed.value.payload;

    if (!std.mem.eql(u8, payload.status, "ok")) {
        const error_msg = payload.error_message orelse "Unknown error";
        std.debug.print("Error: {s}\n", .{error_msg});
        return;
    }

    if (payload.sessions.len == 0) {
        std.debug.print("No active sessions\n", .{});
        return;
    }

    std.debug.print("Active sessions:\n", .{});
    std.debug.print("{s:<20} {s:<12} {s:<8} {s}\n", .{ "NAME", "STATUS", "CLIENTS", "CREATED" });
    std.debug.print("{s}\n", .{"-" ** 60});

    for (payload.sessions) |session| {
        std.debug.print("{s:<20} {s:<12} {d:<8} {s}\n", .{ session.name, session.status, session.clients, session.created_at });
    }
}
