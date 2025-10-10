const std = @import("std");
const posix = std.posix;

test "daemon attach creates pty session" {
    const allocator = std.testing.allocator;

    // Start the daemon process with SHELL=/bin/bash
    const daemon_args = [_][]const u8{ "zig-out/bin/zmx", "daemon" };
    var daemon_process = std.process.Child.init(&daemon_args, allocator);
    daemon_process.stdin_behavior = .Ignore;
    daemon_process.stdout_behavior = .Pipe;
    daemon_process.stderr_behavior = .Pipe;

    // Set SHELL environment variable
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

    // Run zmx attach command
    const attach_args = [_][]const u8{ "zig-out/bin/zmx", "attach" };
    var attach_process = std.process.Child.init(&attach_args, allocator);
    attach_process.stdin_behavior = .Ignore;
    attach_process.stdout_behavior = .Pipe;
    attach_process.stderr_behavior = .Pipe;

    const result = try attach_process.spawnAndWait();

    // Check that attach command succeeded
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result);

    // Give time for daemon to process and create PTY
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Verify PTY was created by reading daemon output
    const stdout = try daemon_process.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);

    // Parse the child PID from daemon output
    const child_pid_prefix = "child_pid=";
    const pid_start = std.mem.indexOf(u8, stdout, child_pid_prefix) orelse return error.NoPidInOutput;
    const pid_str_start = pid_start + child_pid_prefix.len;
    const pid_str_end = std.mem.indexOfAnyPos(u8, stdout, pid_str_start, "\n ") orelse stdout.len;
    const pid_str = stdout[pid_str_start..pid_str_end];
    const child_pid = try std.fmt.parseInt(i32, pid_str, 10);

    std.debug.print("Extracted child PID: {d}\n", .{child_pid});

    // Verify the process exists in /proc
    const proc_path = try std.fmt.allocPrint(allocator, "/proc/{d}", .{child_pid});
    defer allocator.free(proc_path);

    const proc_dir = std.fs.openDirAbsolute(proc_path, .{}) catch |err| {
        std.debug.print("Process {d} does not exist in /proc: {s}\n", .{ child_pid, @errorName(err) });
        return err;
    };
    proc_dir.close();

    // Verify it's a shell process by reading /proc/<pid>/comm
    const comm_path = try std.fmt.allocPrint(allocator, "/proc/{d}/comm", .{child_pid});
    defer allocator.free(comm_path);

    const comm = std.fs.cwd().readFileAlloc(allocator, comm_path, 1024) catch |err| {
        std.debug.print("Could not read process name: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(comm);

    const process_name = std.mem.trim(u8, comm, "\n ");
    std.debug.print("Child process name: {s}\n", .{process_name});

    // Verify it's bash (as we set SHELL=/bin/bash)
    try std.testing.expectEqualStrings("bash", process_name);

    std.debug.print("✓ PTY session created successfully with bash process (PID {d})\n", .{child_pid});
    std.debug.print("Daemon output:\n{s}\n", .{stdout});
}
