const std = @import("std");
const Cfg = @import("../cfg.zig").Cfg;
const shared = @import("shared.zig");
const socket = @import("../socket.zig");
const ipc = @import("../ipc.zig");
const send_cmd = @import("send_cmd.zig");

pub fn cmdSend(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const session_name = args.next() orelse "";
    if (shared.isHelp(session_name)) return shared.printUsage("send", "<name> <text...>");
    if (session_name.len == 0) return error.SessionNameRequired;

    var text_parts: std.ArrayList([]const u8) = .empty;
    defer text_parts.deinit(alloc);
    while (args.next()) |arg| try text_parts.append(alloc, arg);

    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    const socket_path = socket.getSocketPathChecked(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => return,
        error.OutOfMemory => |e| return e,
    };
    return send_cmd.send(cfg, sesh, socket_path, text_parts.items, .Input);
}

pub fn cmdPrint(alloc: std.mem.Allocator, cfg: *Cfg, args: *std.process.ArgIterator) !void {
    const session_name = args.next() orelse "";
    if (shared.isHelp(session_name)) return shared.printUsage("print", "<name> <text...>");
    if (session_name.len == 0) return error.SessionNameRequired;

    var text_parts: std.ArrayList([]const u8) = .empty;
    defer text_parts.deinit(alloc);
    while (args.next()) |arg| try text_parts.append(alloc, arg);

    const sesh = try socket.getSeshName(alloc, session_name);
    defer alloc.free(sesh);
    const socket_path = socket.getSocketPathChecked(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => return,
        error.OutOfMemory => |e| return e,
    };
    return send_cmd.send(cfg, sesh, socket_path, text_parts.items, .Output);
}
