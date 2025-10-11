const std = @import("std");
const posix = std.posix;
const clap = @import("clap");
const config_mod = @import("config.zig");
const protocol = @import("protocol.zig");

const params = clap.parseParamsComptime(
    \\-s, --socket-path <str>  Path to the Unix socket file
    \\<str>
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

    const session_name = res.positionals[0] orelse {
        std.debug.print("Usage: zmx kill <session-name>\n", .{});
        std.process.exit(1);
    };

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

    try protocol.writeJson(
        allocator,
        socket_fd,
        .kill_session_request,
        protocol.KillSessionRequest{ .session_name = session_name },
    );

    var buffer: [4096]u8 = undefined;
    const bytes_read = try posix.read(socket_fd, &buffer);

    if (bytes_read == 0) {
        std.debug.print("No response from daemon\n", .{});
        return;
    }

    const response = buffer[0..bytes_read];
    const newline_idx = std.mem.indexOf(u8, response, "\n") orelse bytes_read;
    const msg_line = response[0..newline_idx];

    const parsed = try protocol.parseMessage(protocol.KillSessionResponse, allocator, msg_line);
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.payload.status, "ok")) {
        std.debug.print("Killed session: {s}\n", .{session_name});
    } else {
        const error_msg = parsed.value.payload.error_message orelse "Unknown error";
        std.debug.print("Failed to kill session: {s}\n", .{error_msg});
        std.process.exit(1);
    }
}
