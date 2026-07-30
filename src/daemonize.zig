const std = @import("std");
const lib_posix = @import("posix.zig");
const Cfg = @import("cfg.zig");
const socket = @import("socket.zig");
const ipc = @import("ipc.zig");
const assert = std.debug.assert;
const log = @import("log.zig");
const cross = @import("cross.zig");

const Cmd = struct {
    file: [*:0]const u8,
    argv_ptr: [*:null]const ?[*:0]const u8,
};

pub fn createCmdZ(def_shell: []const u8, is_task_mode: bool, command: ?[]const []const u8) !Cmd {
    const gpa = std.heap.c_allocator;

    if (command) |cmd_args| {
        const argv = try gpa.allocSentinel(?[*:0]const u8, cmd_args.len, null);
        for (cmd_args, 0..) |arg, i| {
            argv[i] = try gpa.dupeZ(u8, arg);
        }
        return .{
            .file = argv[0].?,
            .argv_ptr = argv.ptr,
        };
    }

    const z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{def_shell}, 0);
    const shell: [:0]const u8 = if (is_task_mode) "bash" else z;

    // Use "-shellname" as argv[0] to signal login shell (traditional method)
    const login_shell = try std.fmt.allocPrintSentinel(gpa, "-{s}", .{std.fs.path.basename(shell)}, 0);
    const argv = try gpa.allocSentinel(?[*:0]const u8, 1, null);
    argv[0] = login_shell.ptr;

    return .{
        .file = shell,
        .argv_ptr = argv,
    };
}

/// Runs in the forked child. Either execs or returns an error (caller
/// must exit on error -- returning would fall through to parent code).
fn exec(sesh_name: []const u8, cmd: Cmd) !noreturn {
    const gpa = std.heap.c_allocator;

    // main() set SIGPIPE to SIG_IGN, which (unlike handlers) survives
    // exec. Restore the default so the shell and its children behave
    // normally (e.g. `yes | head` should exit 141 via SIGPIPE).
    const dfl: lib_posix.Sigaction = .{
        .handler = .{ .handler = lib_posix.SIG.DFL },
        .mask = lib_posix.sigemptyset(),
        .flags = 0,
    };
    lib_posix.sigaction(lib_posix.SIG.PIPE, &dfl, null);

    const session_env = try std.fmt.allocPrintSentinel(
        gpa,
        "ZMX_SESSION={s}",
        .{sesh_name},
        0,
    );
    _ = cross.c.putenv(session_env.ptr);

    const err = lib_posix.execvpeZ(cmd.file, cmd.argv_ptr, std.c.environ);
    std.log.err("execvpe failed: cmd={s} err={s}", .{ cmd.file, @errorName(err) });
    lib_posix.exit(1);
}

pub const PtyInfo = struct {
    master_fd: c_int = undefined,
    pid: c_int = undefined,
};

/// spawnPty runs forkpty() and executes the shell or shell command the user
/// provides.
///
/// This is the second fork in the double-fork technique explained in the
/// daemonize() comment.
pub fn spawnPty(sesh_name: []const u8, cmd: Cmd) !PtyInfo {
    const size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
    var ws: cross.c.struct_winsize = .{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = size.xpixel,
        .ws_ypixel = size.ypixel,
    };

    var master_fd: c_int = undefined;
    const pid = cross.forkpty(&master_fd, null, null, &ws);
    if (pid < 0) {
        return error.ForkPtyFailed;
    }

    if (pid == 0) { // child pid code path
        // In the forked child, ANY error must exit rather than propagate:
        // a returned error falls through to the parent code path below,
        // running a second daemon on the same socket (or worse, hitting
        // errdefers that delete the parent's socket file).
        exec(sesh_name, cmd) catch |err| {
            std.log.err("child setup failed: {s}", .{@errorName(err)});
            lib_posix.exit(1);
        };
        unreachable; // exec() either execs or exits, never returns ok
    }
    // master pid code path
    std.log.info("pty spawned session={s} pid={d}", .{ sesh_name, pid });

    // make pty non-blocking
    const flags = try lib_posix.fcntl(master_fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(master_fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);

    return .{
        .master_fd = master_fd,
        .pid = pid,
    };
}

/// daemonize is the first fork in a double-fork technique to create a
/// completely disconnected session (group of processes).
///
/// When launching a daemon, you normally set the child process of the fork to
/// be the session leader via setsid() which creates a new session that does
/// *not* have a controlling terminal. This is important because we don't want
/// a controlling terminal for our daemon or else our daemon could receive
/// signals to shutdown when the controlling terminal closes.
///
/// However, if the first fork's child process is also the daemon process, then
/// it's technically possible for the daemon to open a terminal device
/// (e.g. open("/dev/console", O_RDWR)) and then it would acquire a controlling
/// terminal! A controlling terminal would expose the daemon to
/// terminal-generated signals (e.g. SIGINT) or SIGHUP from terminal disconnect
/// which could kill the daemon.
///
/// By forking a second time, the grandchild process (the daemon) is not the
/// session leader. Per POSIX, only a process that is the session leader can
/// acquire a controlling terminal.
///
/// Apparently this is considered "being paranoid" but appears to be a standard
/// practice for daemons so we're doing it anyway.
///
/// https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap11.html#tag_11_01_03
/// https://stackoverflow.com/a/16317668
pub fn daemonize(sesh_name: []const u8, cmd: Cmd, keep_fds_open: []i32) !PtyInfo {
    // creates the daemon
    const pid = try lib_posix.fork();
    assert(pid != -1);

    if (pid > 0) { // parent (client)
        // cannot use a passed-in io or alloc after a fork so we create what we need
        // after the fork()
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const io = threaded.io();
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real) catch unreachable;
        return error.IsClientProc;
    }

    assert(pid == 0); // child (daemon's parent in double-fork)
    // becomes the session leader and detaches process from its controlling terminal
    _ = try lib_posix.setsid();

    // If the daemon was launched from a mounted filesystem (e.g., a USB drive
    // at /mnt/usb), keeping that directory as the working directory pins the
    // mount which means it can't be unmounted while the daemon holds it.
    // chdir("/") moves to the root filesystem, which is never unmounted.
    const dir_path_c = try lib_posix.toPosixPath("/");
    try lib_posix.chdirZ(&dir_path_c);

    // The parent may have had a restrictive umask (e.g., 0077) that would
    // prevent the daemon from creating files with the intended permissions.
    // Setting umask(0) lets the daemon explicitly control permissions via
    // open()/creat() mode arguments, rather than inheriting an unpredictable
    // mask.
    _ = std.c.umask(0); // requires libc on linux

    // Redirect stdin/stdout/stderr to /dev/null. The daemon
    // communicates via its unix socket, not stdio. Without
    // this, any pipe on FDs 0-2 (e.g. from bats' `run`
    // keyword) stays open for the daemon's lifetime, causing
    // the caller to hang waiting for EOF.
    {
        const devnull = lib_posix.open(
            "/dev/null",
            .{ .ACCMODE = .RDWR },
            0,
        ) catch |err| {
            std.log.warn("failed to open /dev/null: {s}", .{@errorName(err)});
            return err;
        };
        inline for (.{ lib_posix.STDIN_FILENO, lib_posix.STDOUT_FILENO, lib_posix.STDERR_FILENO }) |fd| {
            _ = lib_posix.dup2(devnull, fd) catch |err| {
                std.log.warn("dup2 /dev/null -> {d}: {s}", .{ fd, @errorName(err) });
                return err;
            };
        }
        var found = false;
        for (keep_fds_open) |fd| {
            if (devnull == fd) found = true;
        }
        if (devnull > 2 and !found) lib_posix.close(devnull);
    }

    // Close file descriptors inherited from the parent that the
    // daemon doesn't need. This prevents test harnesses (like
    // bats) from hanging: they wait for their internal FDs (3+)
    // to close before exiting.
    //
    // Skip any fds that the caller wants to keep open, e.g. server_sock_fd
    // (needed for IPC) and dir.fd (needed to delete the socket file on
    // shutdown).
    {
        var fd: i32 = 3;
        while (fd < 64) : (fd += 1) {
            var found = false;
            for (keep_fds_open) |kfd| {
                if (fd == kfd) found = true;
            }
            if (!found) _ = std.c.close(fd);
        }
    }

    return spawnPty(sesh_name, cmd);
}
