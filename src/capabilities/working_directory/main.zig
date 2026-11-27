//! OSC 7 working directory restoration for zmx sessions.
//! Shells send OSC 7 to tell a terminal which directory they are in. This
//! capability sends that directory to a newly attached terminal. Ghostty and the
//! daemon keep their existing directory tracking for session listings and new shells.
const std = @import("std");
const api = @import("capability-api");

pub const definition = makeDefinition();

fn makeDefinition() api.Definition {
    var result = api.Definition.of("osc7", Capability);

    // Directory restoration is existing zmx behavior, so callers get it without
    // needing to select this capability in their optional additions.
    result.always_active = true;
    return result;
}

/// 'Capability' restores one session's working directory using Ghostty's saved value.
const Capability = struct {
    pub fn init(_: std.mem.Allocator) !Capability {
        return .{};
    }

    pub fn deinit(_: *Capability, _: std.mem.Allocator) void {}

    pub fn observe(_: *Capability, _: std.mem.Allocator, _: api.Event, _: *api.Reply) void {}

    /// Write the OSC 7 message that restores the directory in a reconnecting terminal.
    pub fn restore(_: *Capability, term: *const api.Terminal, writer: *std.Io.Writer) !void {
        // Ghostty already remembers OSC 7 in its terminal state. Read that value rather
        // than keeping a second copy that could disagree after an update or reset.
        const pwd = term.getPwd() orelse return;
        if (pwd.len == 0) {
            return;
        }

        // getPwd omits Ghostty's internal NUL sentinel. Sending that sentinel
        // would corrupt clients that save OSC 7 in their own session files.
        // github.com/neurosnap/zmx/issues/222
        try writer.print("\x1b]7;{s}\x1b\\", .{pwd});
    }
};
