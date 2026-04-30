const std = @import("std");

pub fn get(comptime name: [:0]const u8) ?[:0]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}
