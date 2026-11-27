//! The capability runtime owns per-session data and connects callbacks to the
//! daemon's parser, program input, and reconnect output. Capability authors use
//! the separate public API in 'src/capabilities.zig'.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const api = @import("capability-api");
const Allocator = std.mem.Allocator;
const Terminal = api.Terminal;
const Definition = api.Definition;
const Event = api.Event;
const Reply = api.Reply;

/// An 'Output' is the destination for capability messages sent to one reconnecting client.
/// The runtime prepares each capability's messages before submitting them here.
pub const Output = struct {
    /// State supplied by the daemon, passed unchanged to 'write'.
    context: *anyopaque,

    /// Append all bytes or return an error without appending any, so a failure
    /// cannot leave incomplete restore messages. Copy bytes retained after return.
    write: *const fn (*anyopaque, []const u8) anyerror!void,
};

/// A 'Replies' value supplies daemon callbacks for program input and attachment state.
/// Capabilities receive the restricted 'Reply' handle instead of these callbacks.
pub const Replies = struct {
    /// State supplied by the daemon, passed unchanged to both callbacks.
    context: *anyopaque,

    /// Report whether a terminal client is attached. Connections used only to
    /// query session information or follow output do not count.
    isAttached: *const fn (*anyopaque) bool,

    /// Copy a complete answer into program input using the session allocator,
    /// or drop the whole answer if the queue cannot accept it.
    write: *const fn (*anyopaque, Allocator, []const u8) void,
};

/// Reject repeated capability names before starting a daemon or creating its data.
/// Keeping one instance per name avoids repeating a capability's reconnect messages.
pub fn validate(definitions: []const Definition) !void {
    for (definitions, 0..) |definition, index| {
        for (definitions[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, definition.name)) {
                return error.DuplicateCapability;
            }
        }
    }
}

/// A 'Session' owns a daemon's capability instances across terminal connections.
/// It borrows the definitions, which must remain valid and unchanged until 'deinit'.
pub const Session = struct {
    alloc: Allocator,
    definitions: []const Definition,

    /// One state per definition, in the same order.
    states: []*anyopaque,

    /// Start the configured list in order, unwinding all earlier instances on failure.
    /// Configuration has already added always-active definitions.
    pub fn init(alloc: Allocator, definitions: []const Definition) !Session {
        try validate(definitions);

        const states = try alloc.alloc(*anyopaque, definitions.len);
        errdefer alloc.free(states);

        var initialized: usize = 0;

        // A later capability can fail after earlier capabilities have allocated data.
        // Unwind those successful creations so the failed startup leaves none behind.
        errdefer {
            while (initialized > 0) {
                initialized -= 1;
                definitions[initialized].deinit(states[initialized], alloc);
            }
        }

        for (definitions, states) |definition, *state| {
            state.* = try definition.create(alloc);
            initialized += 1;
        }

        return .{
            .alloc = alloc,
            .definitions = definitions,
            .states = states,
        };
    }

    /// Release every capability's saved information in reverse startup order.
    /// Stop using the session's parser before calling this method.
    pub fn deinit(self: *Session) void {
        var remaining = self.states.len;
        while (remaining > 0) {
            remaining -= 1;
            self.definitions[remaining].deinit(self.states[remaining], self.alloc);
        }

        self.alloc.free(self.states);
    }

    // Every capability observes the event so its state stays complete. The shared
    // reply handle prevents duplicate answers without skipping later observations.
    fn observe(self: *Session, event: Event, replies: Replies) void {
        var reply: Reply = .{
            .alloc = self.alloc,
            .context = replies.context,
            .write = replies.write,
            .claimed = replies.isAttached(replies.context),
        };

        for (self.definitions, self.states) |definition, state| {
            definition.observe(state, self.alloc, event, &reply);
        }
    }

    /// Collect and queue each capability's reconnect messages through 'output'.
    fn restore(self: *Session, term: *const Terminal, output: Output) void {
        for (self.definitions, self.states) |definition, state| {
            var buffer: std.Io.Writer.Allocating = .init(self.alloc);
            defer buffer.deinit();

            // Collect every restore command before queuing any of them. Otherwise
            // a failed write could clear the terminal's old data without replacing it.
            definition.restore(state, term, &buffer.writer) catch |err| {
                std.log.warn("capability {s} could not restore state err={s}", .{ definition.name, @errorName(err) });
                continue;
            };

            if (buffer.writer.buffered().len == 0) {
                continue;
            }

            output.write(output.context, buffer.writer.buffered()) catch |err| {
                std.log.warn("capability {s} could not queue state err={s}", .{ definition.name, @errorName(err) });
            };
        }
    }
};

/// A 'Handler' delivers parsed actions and accepted shell prompts to capabilities
/// while preserving Ghostty's normal terminal updates.
const Handler = struct {
    terminal: ghostty.TerminalStream.Handler,
    session: *Session,
    replies: Replies,

    pub fn vt(self: *Handler, comptime tag: ghostty.StreamAction.Tag, value: ghostty.StreamAction.Value(tag)) void {
        if (self.session.states.len != 0) {
            self.session.observe(.{ .action = @unionInit(ghostty.StreamAction, @tagName(tag), value) }, self.replies);
        }

        self.terminal.vt(tag, value);
    }

    fn semanticPrompt(terminal: *ghostty.TerminalStream.Handler, event: ghostty.SemanticPrompt) void {
        const self: *Handler = @fieldParentPtr("terminal", terminal);
        self.session.observe(.{ .semantic_prompt = event }, self.replies);
    }

    pub fn deinit(self: *Handler) void {
        self.terminal.deinit();
    }
};

/// A 'Stream' parses program output once for Ghostty and the selected capabilities.
pub const Stream = ghostty.Stream(Handler);

/// Create the parser and connect capability replies to program input.
/// Keep 'term', 'session', and 'replies.context' at stable addresses until it ends.
/// An empty session collects no unknown OSC messages or unfinished commands.
pub fn initStream(term: *Terminal, session: *Session, replies: Replies) Stream {
    var continuation_max_bytes: usize = 0;
    var osc_unknown_max_bytes: usize = 0;
    for (session.definitions) |definition| {
        continuation_max_bytes = @max(continuation_max_bytes, definition.continuation_max_bytes);
        osc_unknown_max_bytes = @max(osc_unknown_max_bytes, definition.osc_unknown_max_bytes);
    }

    var terminal = term.vtHandler();
    if (session.states.len != 0) {
        terminal.effects.semantic_prompt = Handler.semanticPrompt;
    }

    return .init(.{
        .allocator = session.alloc,
        .handler = .{
            .terminal = terminal,
            .session = session,
            .replies = replies,
        },
        .continuation_max_bytes = continuation_max_bytes,
        .osc_unknown_max_bytes = osc_unknown_max_bytes,
    });
}

/// Queue capability messages after the saved screen and before live output.
/// Each capability's messages are submitted in full or skipped, without preventing
/// later capabilities from restoring. The unfinished terminal command comes last.
pub fn restore(stream: *Stream, output: Output) void {
    stream.handler.session.restore(stream.handler.terminal.terminal, output);

    // The unfinished command comes last so the terminal cannot mistake capability
    // restore messages for part of the command the program had started sending.
    var buffer: std.Io.Writer.Allocating = .init(stream.handler.session.alloc);
    defer buffer.deinit();

    stream.writeContinuation(&buffer.writer) catch |err| switch (err) {
        error.ContinuationDisabled => return,
        else => {
            std.log.warn("could not restore unfinished terminal sequence err={s}", .{@errorName(err)});
            return;
        },
    };

    if (buffer.writer.buffered().len == 0) {
        return;
    }

    output.write(output.context, buffer.writer.buffered()) catch |err| {
        std.log.warn("could not queue unfinished terminal sequence err={s}", .{@errorName(err)});
    };
}
