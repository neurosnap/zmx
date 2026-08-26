const std = @import("std");
const cfg_mod = @import("cfg.zig");
const socket_mod = @import("socket.zig");
const ipc_mod = @import("ipc.zig");
const signal_mod = @import("signal.zig");

/// Public dependency-free surface for embedders. This first layer exposes only
/// configuration, wire protocol, and signal helpers that compile without
/// ghostty-vt or CLI build_options.
pub const Cfg = cfg_mod.Cfg;

pub const socket = socket_mod;
pub const ipc = ipc_mod;

/// Ghostty-coupled daemon runtime for embedders that supply `ghostty-vt`.
/// This import stays lazy, so dependency-free consumers never resolve it.
pub const runtime = @import("loop.zig");

pub const ignoreSigpipe = signal_mod.ignoreSigpipe;

test "runtime namespace exposes the upstream daemon implementation" {
    _ = runtime.Daemon;
    _ = runtime.Client;
}
