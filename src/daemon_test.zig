const std = @import("std");
const posix = std.posix;

test "daemon lifecycle: attach, verify PTY, detach, shutdown" {
    const allocator = std.testing.allocator;

    // 1. Start the daemon process with SHELL=/bin/bash
    std.debug.print("\n=== Starting daemon ===\n", .{});
    const daemon_args = [_][]const u8{ "zig-out/bin/zmx", "daemon" };
    var daemon_process = std.process.Child.init(&daemon_args, allocator);
    daemon_process.stdin_behavior = .Ignore;
    daemon_process.stdout_behavior = .Ignore;
    daemon_process.stderr_behavior = .Pipe; // daemon uses stderr for debug output

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("SHELL", "/bin/bash");
    daemon_process.env_map = &env_map;

    try daemon_process.spawn();
    defer {
        _ = daemon_process.kill() catch {};
    }

    // Give daemon time to start
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // 2. Attach to a test session
    std.debug.print("=== Attaching to session 'test' ===\n", .{});
    const attach_args = [_][]const u8{ "zig-out/bin/zmx", "attach", "test" };
    var attach_process = std.process.Child.init(&attach_args, allocator);
    attach_process.stdin_behavior = .Pipe;
    attach_process.stdout_behavior = .Ignore; // We don't read it
    attach_process.stderr_behavior = .Ignore; // We don't read it

    try attach_process.spawn();
    defer {
        _ = attach_process.kill() catch {};
    }

    // Give time for PTY session to be created
    std.Thread.sleep(300 * std.time.ns_per_ms);

    // 3. Verify PTY was created by reading daemon stderr with timeout
    std.debug.print("=== Verifying PTY creation ===\n", .{});
    const out_file = daemon_process.stderr.?;
    const flags = try posix.fcntl(out_file.handle, posix.F.GETFL, 0);
    const new_flags = posix.O{
        .ACCMODE = .RDONLY,
        .CREAT = false,
        .EXCL = false,
        .NOCTTY = false,
        .TRUNC = false,
        .APPEND = false,
        .NONBLOCK = true,
    };
    _ = try posix.fcntl(out_file.handle, posix.F.SETFL, @as(u32, @bitCast(new_flags)) | flags);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_len: usize = 0;
    const needle = "child_pid";
    const deadline_ms = std.time.milliTimestamp() + 3000;

    while (std.time.milliTimestamp() < deadline_ms) {
        var pfd = [_]posix.pollfd{.{ .fd = out_file.handle, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&pfd, 200);
        if ((pfd[0].revents & posix.POLL.IN) != 0) {
            const n = posix.read(out_file.handle, stdout_buf[stdout_len..]) catch |e| switch (e) {
                error.WouldBlock => 0,
                else => return e,
            };
            stdout_len += n;
            if (std.mem.indexOf(u8, stdout_buf[0..stdout_len], needle) != null) break;
        }
    }

    const stdout = stdout_buf[0..stdout_len];
    std.debug.print("Daemon output ({d} bytes): {s}\n", .{ stdout_len, stdout });

    // Parse the child PID from daemon output (format: "child_pid={d}")
    const child_pid_prefix = "child_pid=";
    const pid_start = std.mem.indexOf(u8, stdout, child_pid_prefix) orelse {
        std.debug.print("Expected 'child_pid=' in output\n", .{});
        return error.NoPidInOutput;
    };
    const pid_str_start = pid_start + child_pid_prefix.len;
    const pid_str_end = std.mem.indexOfAnyPos(u8, stdout, pid_str_start, "\n ") orelse stdout.len;
    const pid_str = stdout[pid_str_start..pid_str_end];
    const child_pid = try std.fmt.parseInt(i32, pid_str, 10);

    std.debug.print("✓ PTY created with child PID: {d}\n", .{child_pid});

    // Verify the shell process exists
    const proc_path = try std.fmt.allocPrint(allocator, "/proc/{d}", .{child_pid});
    defer allocator.free(proc_path);

    var proc_dir = std.fs.openDirAbsolute(proc_path, .{}) catch |err| {
        std.debug.print("Process {d} does not exist: {s}\n", .{ child_pid, @errorName(err) });
        return err;
    };
    proc_dir.close();

    // Verify it's bash
    const comm_path = try std.fmt.allocPrint(allocator, "/proc/{d}/comm", .{child_pid});
    defer allocator.free(comm_path);

    const comm = try std.fs.cwd().readFileAlloc(allocator, comm_path, 1024);
    defer allocator.free(comm);

    const process_name = std.mem.trim(u8, comm, "\n ");
    try std.testing.expectEqualStrings("bash", process_name);
    std.debug.print("✓ Shell process verified: {s}\n", .{process_name});

    // 4. Send detach command
    std.debug.print("=== Detaching from session ===\n", .{});
    const detach_seq = [_]u8{ 0x00, 'd' }; // Ctrl+Space followed by 'd'
    _ = try attach_process.stdin.?.write(&detach_seq);
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Kill attach process (will close stdin internally)
    _ = attach_process.kill() catch {};
    std.debug.print("✓ Detached from session\n", .{});

    // 5. Shutdown daemon
    std.debug.print("=== Shutting down daemon ===\n", .{});
    _ = daemon_process.kill() catch {};
    std.debug.print("✓ Daemon killed\n", .{});

    std.debug.print("=== Test completed successfully ===\n", .{});
}
