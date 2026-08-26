//! Compile-only reachability check: every decl embedders consume from the `zmx`
//! module must be analysable with neither `ghostty-vt` nor `build_options`
//! wired in. This is a compile-time assertion, not a test — a `test` target
//! cannot express it, because referencing dependency-coupled files also pulls
//! in their ghostty-coupled test blocks.
const lib = @import("lib.zig");

comptime {
    _ = lib.Cfg;
    _ = lib.socket;
    _ = lib.ipc;
    _ = &lib.ignoreSigpipe;
}
