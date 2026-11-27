//! Capabilities add session features without putting their protocol rules in the
//! daemon loop. They can remember program reports, answer queries while detached,
//! and restore information on reconnect. They cannot change live client output.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const Allocator = std.mem.Allocator;

/// A 'Terminal' is Ghostty's saved screen and terminal settings for one session.
/// Capabilities can read its saved information instead of keeping another copy.
pub const Terminal = ghostty.Terminal;

/// An 'Event' is an output notification used to update a capability's saved state.
/// Its bytes are borrowed until 'observe' returns. Copy any that must be remembered.
pub const Event = union(enum) {
    /// A parsed output action, delivered before Ghostty applies it to 'Terminal'.
    action: ghostty.StreamAction,

    /// A shell notification delivered after Ghostty accepts it, such as a new prompt.
    /// Rejected notifications are omitted so capability state agrees with Ghostty.
    semantic_prompt: ghostty.SemanticPrompt,
};

/// A 'Reply' is the handle for answering a program's query during 'observe'.
/// All capabilities share it for the event. The first answer wins while detached.
/// While a terminal is attached, zmx leaves answering to it and refuses capability
/// replies. The handle is valid only until 'observe' returns.
pub const Reply = struct {
    alloc: Allocator,
    context: *anyopaque,
    write: *const fn (*anyopaque, Allocator, []const u8) void,
    claimed: bool,

    /// Submit a complete answer, returning false if a terminal or earlier capability
    /// owns the reply. True means allowed to send. A full input queue can still drop
    /// the answer. The caller may reuse the bytes after return.
    pub fn send(self: *Reply, bytes: []const u8) bool {
        if (self.claimed) {
            return false;
        }

        self.claimed = true;
        self.write(self.context, self.alloc, bytes);
        return true;
    }
};

/// A 'Definition' describes a capability's implementation and parser settings.
/// Use 'Definition.of' to describe a Zig struct without starting it.
pub const Definition = struct {
    /// The configuration name. 'Definition.of' supplies compile-time storage.
    /// A replacement name must remain valid and unchanged while in use.
    name: []const u8,

    /// Include this in every new daemon before optional capabilities.
    /// Only definitions registered in registry.zig participate in this policy.
    always_active: bool = false,

    /// Runtime callbacks supplied by 'Definition.of'. Capability authors implement
    /// the typed methods described there instead of constructing these directly.
    create: *const fn (Allocator) anyerror!*anyopaque,
    deinit: *const fn (*anyopaque, Allocator) void,
    observe: *const fn (*anyopaque, Allocator, Event, *Reply) void,
    restore: *const fn (*anyopaque, *const Terminal, *std.Io.Writer) anyerror!void,

    /// Bytes reserved to replay an unfinished terminal command after restore messages.
    /// Allow for the entire command, including its escape prefix and terminator.
    /// The parser uses the largest selected allowance. Zero requests none.
    continuation_max_bytes: usize = 4096,

    /// Bytes reserved for unrecognized OSC commands delivered as 'action.osc_unknown'.
    /// The parser uses the largest selected allowance. Zero requests none.
    /// Check the event's truncation flag and enforce your own protocol limit,
    /// since another capability may request a larger allowance.
    osc_unknown_max_bytes: usize = 0,

    /// Describe 'T', a struct holding one session's state with these methods
    ///
    /// ```zig
    /// const api = zmx.capabilities;
    /// pub fn init(alloc: std.mem.Allocator) !T
    /// pub fn deinit(self: *T, alloc: std.mem.Allocator) void
    /// pub fn observe(self: *T, alloc: std.mem.Allocator,
    ///     event: api.Event, reply: *api.Reply) void
    /// pub fn restore(self: *T, term: *const api.Terminal,
    ///     writer: *std.Io.Writer) !void
    /// ```
    ///
    /// The runtime creates one 'T' per daemon and keeps it across disconnects.
    /// All callbacks run on the daemon loop and must return promptly. 'init', 'observe',
    /// and 'deinit' share an allocator. If 'init' fails, it must clean up its own
    /// allocations. Only successful instances receive 'deinit'.
    ///
    /// 'observe' updates saved state, even if another capability has already replied.
    /// See 'Event' and 'Reply' for ordering, borrowing, and reply ownership.
    ///
    /// 'restore' writes complete terminal commands that replay saved information.
    /// The writer is temporary, and 'term' provides Ghostty's existing state.
    /// On failure, all messages from this call are discarded. Previously queued
    /// output and later capabilities are unaffected.
    pub fn of(comptime name: []const u8, comptime T: type) Definition {
        const Adapter = struct {
            fn create(alloc: Allocator) !*anyopaque {
                const state = try alloc.create(T);
                errdefer alloc.destroy(state);

                state.* = try T.init(alloc);
                return state;
            }

            fn deinit(context: *anyopaque, alloc: Allocator) void {
                const state: *T = @ptrCast(@alignCast(context));
                state.deinit(alloc);
                alloc.destroy(state);
            }

            fn observe(context: *anyopaque, alloc: Allocator, event: Event, reply: *Reply) void {
                const state: *T = @ptrCast(@alignCast(context));
                state.observe(alloc, event, reply);
            }

            fn restore(context: *anyopaque, term: *const Terminal, writer: *std.Io.Writer) anyerror!void {
                const state: *T = @ptrCast(@alignCast(context));
                try state.restore(term, writer);
            }
        };

        return .{
            .name = name,
            .create = Adapter.create,
            .deinit = Adapter.deinit,
            .observe = Adapter.observe,
            .restore = Adapter.restore,
        };
    }
};
