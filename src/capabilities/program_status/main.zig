//! Optional OSC 7501 Program Status support for zmx sessions.
//! Programs use this protocol to report that they are working, waiting for
//! help, or finished. A terminal application can use this to show which sessions
//! need attention, without trying to infer it from the text on the screen.
//!
//! Forwarding those messages alone leaves a reconnecting terminal unaware of
//! earlier reports. This capability remembers the latest report for each task
//! and sends that information when a terminal connects. It also answers support
//! queries while no terminal is connected, so programs can begin reporting then.
//! Keeping these task and query rules here lets the daemon use the capability
//! API without knowing the particulars of OSC 7501.
//! www.superlogical.com/rex/docs/build/program-status
const std = @import("std");
const ghostty = @import("ghostty-vt");
const Report = ghostty.osc.Command.ProgramStatus.Report;
const api = @import("capability-api");

pub const definition = makeDefinition();

fn makeDefinition() api.Definition {
    var result = api.Definition.of("osc7501", Capability);

    // Keep enough unfinished output for a whole legal OSC 7501 message.
    // "4096 bytes. The largest legal report is under 3300."
    // www.superlogical.com/rex/docs/build/program-status#limits
    result.continuation_max_bytes = ghostty.osc.program_status.max_sequence_bytes;
    return result;
}

/// 'Capability' handles OSC 7501 for one session, retaining task reports and
/// replying to support queries while no terminal is attached.
const Capability = struct {
    records: Records = .{},

    pub fn init(_: std.mem.Allocator) !Capability {
        return .{};
    }

    pub fn deinit(self: *Capability, alloc: std.mem.Allocator) void {
        self.records.deinit(alloc);
    }

    /// Update saved OSC 7501 task records for program reports, shell prompts, and resets.
    /// Answer support queries when no terminal is attached.
    pub fn observe(self: *Capability, alloc: std.mem.Allocator, event: api.Event, reply: *api.Reply) void {
        switch (event) {
            .action => |action| switch (action) {
                .program_status => |status| switch (status) {
                    .report => |report| self.records.updateFromReport(alloc, report) catch |err| {
                        std.log.warn("could not save OSC 7501 task record err={s}", .{@errorName(err)});
                    },
                    .query => |terminator| {
                        // Answer the program's support query with the protocol's
                        // capability list. Reply.send leaves answering to an attached
                        // terminal and otherwise permits this capability's answer.
                        // www.superlogical.com/rex/docs/build/program-status#feature-detection
                        const prefix = "\x1b]7501;" ++ ghostty.osc.program_status.query_reply;
                        _ = reply.send(switch (terminator) {
                            .bel => prefix ++ "\x07",
                            .st => prefix ++ "\x1b\\",
                        });
                    },
                },

                // "A full reset (RIS) removes every record. A soft reset (DECSTR)
                // does not."
                // www.superlogical.com/rex/docs/build/program-status#records-and-ids
                .full_reset => self.records.updateFromReport(alloc, .{ .state = .clear, .data = "state=clear" }) catch unreachable,
                else => {},
            },
            .semantic_prompt => |prompt| {
                if (prompt.kind == .prompt_start) self.records.removeWorkingAndBlocked(alloc);
            },
        }
    }

    pub fn restore(self: *Capability, _: *const api.Terminal, writer: *std.Io.Writer) !void {
        try self.records.writeReplay(writer);
    }
};

/// 'Records' holds the latest OSC 7501 report for the main program and each named
/// task in one session.
///
/// "A report with no id addresses the root record."
/// "Root and child records exist at the same time. A program can be idle at
/// its prompt while one of its workers is blocked."
/// www.superlogical.com/rex/docs/build/program-status#records-and-ids
const Records = struct {
    // The OSC 7501 spec lists 256 task records per terminal and permits lower limits.
    // "256. Terminals MUST support at least 64."
    // www.superlogical.com/rex/docs/build/program-status#limits
    const max_records = 256;

    // Saved OSC 7501 task records are ordered from oldest update to newest.
    items: std.ArrayList(Report) = .empty,

    // An allocation failure prevented us from saving an OSC 7501 update.
    // Do not send saved OSC 7501 task records to reconnecting clients until
    // an OSC 7501 'clear' without a task ID or a full terminal reset discards
    // all saved task records.
    has_unsaved_update: bool = false,

    fn deinit(self: *Records, alloc: std.mem.Allocator) void {
        self.removeTaskAndChildren(alloc, null);
        self.items.deinit(alloc);
    }

    /// Update saved OSC 7501 task records from a report Ghostty has checked and parsed.
    /// An OSC 7501 'clear' removes the named task and its children. Without an ID,
    /// it removes all records.
    ///
    /// "Each report replaces its record completely. A key missing from the
    /// report is missing from the record afterwards."
    /// www.superlogical.com/rex/docs/build/program-status#records-and-ids
    fn updateFromReport(self: *Records, alloc: std.mem.Allocator, report: Report) !void {
        const id = report.readOption(.id);
        if (report.state == .clear) {
            self.removeTaskAndChildren(alloc, id);
            if (id == null) {
                // Clearing all OSC 7501 task records gives us a known empty state again.
                self.has_unsaved_update = false;
            }

            return;
        }

        // An unsaved OSC 7501 update means we cannot restore every task accurately.
        errdefer self.has_unsaved_update = true;

        // Ghostty reuses the bytes of a parsed OSC 7501 report when it reads
        // more output. Copy them so the saved task record remains valid.
        // Allocate before removing anything so failure preserves existing data.
        const data = try alloc.dupe(u8, report.data);
        errdefer alloc.free(data);

        try self.items.ensureTotalCapacity(alloc, @min(max_records, self.items.items.len + 1));

        for (self.items.items, 0..) |old, index| {
            if (taskIdsMatch(old.readOption(.id), id)) {
                self.removeAt(alloc, index);
                break;
            }
        }

        if (self.items.items.len == max_records) {
            // "When a report would create a record past the cap, the record
            // that was updated least recently is removed to make room."
            // www.superlogical.com/rex/docs/build/program-status#limits
            self.removeAt(alloc, 0);
        }

        self.items.appendAssumeCapacity(.{ .state = report.state, .data = data });
    }

    /// Remove saved OSC 7501 'working' and 'blocked' task records when a shell
    /// prompt begins.
    ///
    /// "There is no heartbeat, and terminals MUST NOT require re-sending to keep
    /// a record alive. When the process attached to the terminal exits, or a new
    /// shell prompt begins (OSC 133 A), the terminal MUST drop working and
    /// blocked records and MAY drop idle ones. done and error survive both events."
    /// www.superlogical.com/rex/docs/build/program-status#states
    ///
    /// We keep 'idle' task records, as permitted. Removing a saved task record
    /// does not create or send an OSC 7501 'done' report.
    fn removeWorkingAndBlocked(self: *Records, alloc: std.mem.Allocator) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            switch (self.items.items[index].state) {
                .working, .blocked => self.removeAt(alloc, index),
                else => index += 1,
            }
        }
    }

    /// Write OSC 7501 'clear' followed by the saved task reports for a reconnecting terminal.
    /// With no saved tasks, write only 'clear' so the terminal forgets old records.
    /// Write nothing if a task update could not be saved.
    fn writeReplay(self: *const Records, writer: *std.Io.Writer) !void {
        if (self.has_unsaved_update) {
            // Some OSC 7501 task records may be missing. Do not replace the
            // client's Program Status records with a list we know is incomplete.
            return;
        }

        // "With no id, removes every record on the terminal."
        // www.superlogical.com/rex/docs/build/program-status#states
        try writer.writeAll("\x1b]7501;state=clear\x1b\\");
        for (self.items.items) |report| {
            try writer.print("\x1b]7501;{s}\x1b\\", .{report.data});
        }
    }

    /// Remove saved OSC 7501 records whose task ID equals 'id' or starts with
    /// 'id' followed by '/'. If 'id' is 'null', remove all saved task records.
    ///
    /// "Removes the addressed record and every record beneath it. With no id,
    /// removes every record on the terminal."
    /// www.superlogical.com/rex/docs/build/program-status#states
    ///
    /// An ID of 'build' removes 'build/test' even when no 'build' record exists,
    /// but leaves 'builder' alone.
    fn removeTaskAndChildren(self: *Records, alloc: std.mem.Allocator, id: ?[]const u8) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            var matches = true;
            if (id) |task_id| {
                matches = false;
                if (self.items.items[index].readOption(.id)) |report_id| {
                    const same_task = std.mem.eql(u8, task_id, report_id);

                    const child_task = report_id.len > task_id.len and
                        std.mem.startsWith(u8, report_id, task_id) and
                        report_id[task_id.len] == '/';
                    matches = same_task or child_task;
                }
            }

            if (matches) {
                self.removeAt(alloc, index);
            } else {
                index += 1;
            }
        }
    }

    fn removeAt(self: *Records, alloc: std.mem.Allocator, index: usize) void {
        alloc.free(self.items.orderedRemove(index).data);
    }

    fn taskIdsMatch(first_id: ?[]const u8, second_id: ?[]const u8) bool {
        if (first_id == null) {
            return second_id == null;
        }

        return second_id != null and std.mem.eql(u8, first_id.?, second_id.?);
    }
};
