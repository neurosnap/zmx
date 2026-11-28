//! Capabilities keep terminal protocol state outside the daemon's IPC loop.
//! Each daemon owns the handlers listed in 'States'. One parser delivers their
//! events and updates Ghostty; reconnect restores their messages after the screen.
const std = @import("std");
const ghostty = @import("ghostty-vt");
const Allocator = std.mem.Allocator;

// The fixed set of handlers run by every daemon, in observation and restore order.
const States = struct {
    working_directory: @import("capabilities/working_directory.zig") = .{},
    program_status: @import("capabilities/program_status.zig") = .{},
};

/// An 'Event' is a parsed action or an accepted shell notification.
/// Its bytes are borrowed until 'observe' returns.
pub const Event = union(enum) {
    action: ghostty.StreamAction,
    semantic_prompt: ghostty.SemanticPrompt,
};

/// A 'Reply' lets a handler answer a program's query while no terminal is attached.
/// All handlers share it for one event, and the first answer wins.
pub const Reply = struct {
    alloc: Allocator,
    context: *anyopaque,
    write: *const fn (*anyopaque, Allocator, []const u8) void,
    claimed: bool,

    /// Submit a complete answer if no terminal or earlier handler owns the reply.
    /// The daemon can still drop it if the program's input queue is full.
    pub fn send(self: *Reply, bytes: []const u8) bool {
        if (self.claimed) return false;
        self.claimed = true;
        self.write(self.context, self.alloc, bytes);
        return true;
    }
};

/// 'Replies' connects query answers to the daemon's attachment state and input queue.
pub const Replies = struct {
    context: *anyopaque,
    isAttached: *const fn (*anyopaque) bool,
    write: *const fn (*anyopaque, Allocator, []const u8) void,
};

/// An 'Output' appends restore messages to one reconnecting client.
pub const Output = struct {
    context: *anyopaque,
    /// Copy all bytes into the queue, or return an error without queuing any.
    write: *const fn (*anyopaque, []const u8) anyerror!void,
};

/// A 'Session' holds one daemon's handler state across terminal connections.
pub const Session = struct {
    alloc: Allocator,
    states: States = .{},

    pub fn init(alloc: Allocator) Session {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Session) void {
        inline for (@typeInfo(States).@"struct".field_names) |name| {
            @field(self.states, name).deinit(self.alloc);
        }
    }
};

fn observe(states: anytype, alloc: Allocator, event: Event, replies: Replies) void {
    var reply: Reply = .{
        .alloc = alloc,
        .context = replies.context,
        .write = replies.write,
        .claimed = replies.isAttached(replies.context),
    };
    inline for (@typeInfo(@TypeOf(states.*)).@"struct".field_names) |name| {
        @field(states, name).observe(alloc, event, &reply);
    }
}

fn restoreStates(states: anytype, alloc: Allocator, term: *const ghostty.Terminal, output: Output) void {
    inline for (@typeInfo(@TypeOf(states.*)).@"struct".field_names) |name| {
        restoreOne(name, &@field(states.*, name), alloc, term, output);
    }
}

fn restoreOne(comptime name: []const u8, state: anytype, alloc: Allocator, term: *const ghostty.Terminal, output: Output) void {
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    // Build a handler's entire snapshot before queuing it. A failed restore
    // must not send a clear or half a message without the rest of its data.
    state.restore(term, &buffer.writer) catch |err| {
        std.log.warn("capability {s} could not restore state err={s}", .{ name, @errorName(err) });
        return;
    };
    if (buffer.writer.buffered().len != 0) {
        output.write(output.context, buffer.writer.buffered()) catch |err| {
            std.log.warn("capability {s} could not queue state err={s}", .{ name, @errorName(err) });
        };
    }
}

const Handler = struct {
    terminal: ghostty.TerminalStream.Handler,
    session: *Session,
    replies: Replies,

    pub fn vt(self: *Handler, comptime tag: ghostty.StreamAction.Tag, value: ghostty.StreamAction.Value(tag)) void {
        observe(&self.session.states, self.session.alloc, .{ .action = @unionInit(ghostty.StreamAction, @tagName(tag), value) }, self.replies);
        self.terminal.vt(tag, value);
    }

    fn semanticPrompt(terminal: *ghostty.TerminalStream.Handler, event: ghostty.SemanticPrompt) void {
        const self: *Handler = @fieldParentPtr("terminal", terminal);
        observe(&self.session.states, self.session.alloc, .{ .semantic_prompt = event }, self.replies);
    }

    pub fn deinit(self: *Handler) void {
        self.terminal.deinit();
    }
};

/// A 'Stream' parses output once for the handlers and Ghostty's saved terminal.
pub const Stream = ghostty.Stream(Handler);

/// Connect the parser to a daemon's handlers and query replies.
/// Keep its terminal, session, and reply context at stable addresses until deinit.
pub fn initStream(term: *ghostty.Terminal, session: *Session, replies: Replies) Stream {
    var terminal = term.vtHandler();
    terminal.effects.semantic_prompt = Handler.semanticPrompt;
    return .init(.{
        .allocator = session.alloc,
        .handler = .{ .terminal = terminal, .session = session, .replies = replies },
        // Reconnect may interrupt an escape sequence. Keep a bounded copy so it
        // can resume after the saved screen and complete restore messages.
        .continuation_max_bytes = 4096,
    });
}

/// Queue handler snapshots after the saved screen, then resume unfinished output.
/// A failed snapshot is skipped so other handlers can still restore their data.
pub fn restore(stream: *Stream, output: Output) void {
    const session = stream.handler.session;
    restoreStates(&session.states, session.alloc, stream.handler.terminal.terminal, output);

    // An unfinished command comes last, or it could consume the restore messages.
    var buffer: std.Io.Writer.Allocating = .init(session.alloc);
    defer buffer.deinit();
    stream.writeContinuation(&buffer.writer) catch |err| {
        std.log.warn("could not restore unfinished terminal sequence err={s}", .{@errorName(err)});
        return;
    };
    if (buffer.writer.buffered().len != 0) {
        output.write(output.context, buffer.writer.buffered()) catch |err| {
            std.log.warn("could not queue unfinished terminal sequence err={s}", .{@errorName(err)});
        };
    }
}

const TestObserver = struct {
    count: usize = 0,

    pub fn observe(self: *@This(), _: Allocator, _: Event, reply: *Reply) void {
        self.count += 1;
        _ = reply.send("answer");
    }
};

test "every handler observes each event and query ownership follows attachment" {
    const Context = struct {
        attached: bool = true,
        answers: usize = 0,
        fn isAttached(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.attached;
        }
        fn write(context: *anyopaque, _: Allocator, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.answers += 1;
        }
    };
    var context: Context = .{};
    const replies: Replies = .{ .context = &context, .isAttached = Context.isAttached, .write = Context.write };
    var states: struct { first: TestObserver = .{}, second: TestObserver = .{} } = .{};
    observe(&states, std.testing.allocator, .{ .action = .bell }, replies);
    try std.testing.expectEqual(@as(usize, 0), context.answers);
    context.attached = false;
    observe(&states, std.testing.allocator, .{ .action = .bell }, replies);
    try std.testing.expectEqual(@as(usize, 1), context.answers);
    try std.testing.expectEqual(@as(usize, 2), states.first.count);
    try std.testing.expectEqual(@as(usize, 2), states.second.count);
}

test "a failed handler restore preserves queued output and later snapshots" {
    const Probe = struct {
        bytes: []const u8,
        fail: bool = false,
        pub fn restore(self: *@This(), _: *const ghostty.Terminal, writer: *std.Io.Writer) !void {
            try writer.writeAll(self.bytes);
            if (self.fail) return error.TestRestoreFailed;
        }
    };
    const Queue = struct {
        buffer: std.Io.Writer.Allocating,
        reject_first: bool,
        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.reject_first) {
                self.reject_first = false;
                return error.OutOfMemory;
            }
            try self.buffer.writer.writeAll(bytes);
        }
    };
    const alloc = std.testing.allocator;
    var term = try ghostty.Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);
    var states: struct { first: Probe, bad: Probe, last: Probe } = .{
        .first = Probe{ .bytes = "first" },
        .bad = Probe{ .bytes = "partial", .fail = true },
        .last = Probe{ .bytes = "last" },
    };
    for ([_]bool{ false, true }) |reject_first| {
        var queue: Queue = .{ .buffer = .init(alloc), .reject_first = reject_first };
        defer queue.buffer.deinit();
        try queue.buffer.writer.writeAll("screen");
        restoreStates(&states, alloc, &term, .{ .context = &queue, .write = Queue.write });
        try std.testing.expectEqualStrings(if (reject_first) "screenlast" else "screenfirstlast", queue.buffer.writer.buffered());
    }
}

test {
    _ = @import("capabilities/test.zig");
    _ = @import("capabilities/program_status_test.zig");
    _ = @import("capabilities/working_directory_test.zig");
}
