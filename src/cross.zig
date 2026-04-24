const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

pub const c = switch (builtin.os.tag) {
    .macos => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("sys/sysctl.h"); // sysctl for process name lookup
        @cInclude("termios.h");
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
    .freebsd => @cImport({
        @cInclude("termios.h"); // ioctl and constants
        @cInclude("libutil.h"); // openpty()
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
    else => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("pty.h");
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
};

// Manually declare forkpty for macOS since util.h is not available during cross-compilation
pub const forkpty = if (builtin.os.tag == .macos)
    struct {
        extern "c" fn forkpty(master_fd: *c_int, name: ?[*:0]u8, termp: ?*const c.struct_termios, winp: ?*const c.struct_winsize) c_int;
    }.forkpty
else
    c.forkpty;

/// Returns the basename of the foreground process running on the given PTY fd.
/// Writes into `buf` and returns a slice of it, or null on failure.
pub fn getForegroundProcessName(pty_fd: i32, buf: []u8) ?[]const u8 {
    const pgid = c.tcgetpgrp(pty_fd);
    if (pgid <= 0) return null;

    switch (builtin.os.tag) {
        .macos => {
            // Use KERN_PROC_PGRP to find the process in the foreground group.
            // We walk the process list and find the first process whose pgid matches.
            var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PGRP, @intCast(pgid) };
            var size: usize = 0;
            if (c.sysctl(&mib, mib.len, null, &size, null, 0) != 0) return null;
            if (size == 0) return null;

            // kinfo_proc is large; allocate on heap to avoid blowing the stack
            const kinfo_size = @sizeOf(c.struct_kinfo_proc);
            const count = size / kinfo_size;
            if (count == 0) return null;

            // Use a stack buffer for small lists (usually 1-3 procs), heap otherwise.
            var stack_buf: [8 * @sizeOf(c.struct_kinfo_proc)]u8 align(@alignOf(c.struct_kinfo_proc)) = undefined;
            const heap_needed = size > stack_buf.len;
            const proc_buf: []u8 = if (heap_needed)
                std.heap.c_allocator.alloc(u8, size) catch return null
            else
                stack_buf[0..size];
            defer if (heap_needed) std.heap.c_allocator.free(proc_buf);

            if (c.sysctl(&mib, mib.len, proc_buf.ptr, &size, null, 0) != 0) return null;

            const procs: []c.struct_kinfo_proc = @alignCast(std.mem.bytesAsSlice(c.struct_kinfo_proc, proc_buf[0..size]));
            if (procs.len == 0) return null;

            // p_comm is a null-terminated fixed-length field
            const comm: [*:0]const u8 = @ptrCast(&procs[0].kp_proc.p_comm);
            const name = std.mem.sliceTo(comm, 0);
            const copy_len = @min(name.len, buf.len);
            @memcpy(buf[0..copy_len], name[0..copy_len]);
            return buf[0..copy_len];
        },
        .linux => {
            // /proc/<pid>/comm contains just the process name + newline
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pgid}) catch return null;
            const file = std.fs.openFileAbsolute(path, .{}) catch return null;
            defer file.close();
            const n = file.read(buf) catch return null;
            // strip trailing newline
            const end = if (n > 0 and buf[n - 1] == '\n') n - 1 else n;
            return buf[0..end];
        },
        else => return null,
    }
}
