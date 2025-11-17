const std = @import("std");

// pub const std_options: std.Options = .{
//     .log_level = .err,
// };

pub fn main() !void {
    std.log.info("running cli", .{});
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.skip(); // skip bin name

    const cmd = args.next() orelse {
        std.log.err("must provide cmd", .{});
        return;
    };
    std.log.info("running cmd: {s}", .{cmd});
}
