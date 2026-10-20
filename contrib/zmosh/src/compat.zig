const std = @import("std");

pub const p = @import("posix.zig");

pub const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});
