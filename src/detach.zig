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

    // Find the client_fd file in home directory
    const home_dir = posix.getenv("HOME") orelse "/tmp";

    var session_name: ?[]const u8 = null;
    var client_fd: ?i64 = null;

    // Look for .zmx_client_fd_* files
    var dir = std.fs.cwd().openDir(home_dir, .{ .iterate = true }) catch {
        std.debug.print("Error: Cannot access home directory\n", .{});
        return error.CannotAccessHomeDirectory;
    };
    defer dir.close();

    var dir_iter = dir.iterate();
    while (dir_iter.next() catch null) |entry| {
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
        std.debug.print("Use Ctrl-Space d to detach from within an attached session\n", .{});
        return error.NotAttached;
    }
    defer if (session_name) |name| allocator.free(name);

    const unix_addr = try std.net.Address.initUnix(socket_path);
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(socket_fd);

    posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen()) catch |err| {
        if (err == error.ConnectionRefused) {
            std.debug.print("Error: Unable to connect to zmx daemon at {s}\nPlease start the daemon first with: zmx daemon\n", .{socket_path});
        }
        return err;
    };

    const request_payload = protocol.DetachSessionRequest{
        .session_name = session_name.?,
        .client_fd = client_fd,
    };

    try protocol.writeJson(allocator, socket_fd, .detach_session_request, request_payload);

    var buffer: [4096]u8 = undefined;
    const bytes_read = try posix.read(socket_fd, &buffer);

    if (bytes_read == 0) {
        std.debug.print("No response from daemon\n", .{});
        return;
    }

    const response = buffer[0..bytes_read];
    const newline_idx = std.mem.indexOf(u8, response, "\n") orelse bytes_read;
    const msg_line = response[0..newline_idx];

    const parsed = try protocol.parseMessage(protocol.DetachSessionResponse, allocator, msg_line);
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.payload.status, "ok")) {
        std.debug.print("Detached from session: {s}\n", .{session_name.?});
    } else {
        const error_msg = parsed.value.payload.error_message orelse "Unknown error";
        std.debug.print("Failed to detach: {s}\n", .{error_msg});
        return error.DetachFailed;
    }
}
