//! Save and restore OSC 7501 Program Status for one shell session.
//! A report is an OSC 7501 message sent by a program. A saved task record holds
//! the latest report for that task.
//! www.superlogical.com/rex/docs/build/program-status
const std = @import("std");
const ghostty = @import("ghostty-vt");
const Report = ghostty.osc.Command.ProgramStatus.Report;

/// Saved OSC 7501 Program Status records for one zmx session. Keep the latest
/// report for the main program and each named task.
///
/// "A report with no id addresses the root record."
/// "Root and child records exist at the same time. A program can be idle at
/// its prompt while one of its workers is blocked."
/// www.superlogical.com/rex/docs/build/program-status#records-and-ids
pub const Records = struct {
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

    pub fn deinit(self: *Records, alloc: std.mem.Allocator) void {
        self.removeTaskAndChildren(alloc, null);
        self.items.deinit(alloc);
    }

    /// Return the saved OSC 7501 report for this task, or for the main program if
    /// no task ID is supplied. Return 'null' if no report is saved for it.
    /// The returned bytes belong to this 'Records' instance. Do not keep them
    /// across updates or removals, which may free them.
    pub fn get(self: *const Records, id: ?[]const u8) ?Report {
        for (self.items.items) |report| {
            if (taskIdsMatch(report.readOption(.id), id)) {
                return report;
            }
        }

        return null;
    }

    /// Update saved OSC 7501 task records from a report Ghostty has checked and parsed.
    /// "Each report replaces its record completely. A key missing from the
    /// report is missing from the record afterwards."
    /// An OSC 7501 'clear' removes records whose task ID equals the report's ID
    /// or starts with that ID followed by '/'. Without an ID, it removes all records.
    /// www.superlogical.com/rex/docs/build/program-status#records-and-ids
    pub fn updateFromReport(self: *Records, alloc: std.mem.Allocator, report: Report) !void {
        const id = report.readOption(.id);
        if (report.state == .clear) {
            self.removeTaskAndChildren(alloc, id);
            if (id == null) {
                // Clearing all OSC 7501 task records gives us a known empty state again.
                // "A full reset (RIS) removes every record. A soft reset (DECSTR)
                // does not."
                // Ghostty sends this same OSC 7501 'clear' callback for a full reset.
                // www.superlogical.com/rex/docs/build/program-status#records-and-ids
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
    /// prompt begins or the process exits.
    ///
    /// "There is no heartbeat, and terminals MUST NOT require re-sending to keep
    /// a record alive. When the process attached to the terminal exits, or a new
    /// shell prompt begins (OSC 133 A), the terminal MUST drop working and
    /// blocked records and MAY drop idle ones. done and error survive both events."
    /// www.superlogical.com/rex/docs/build/program-status#states
    ///
    /// We keep 'idle' task records, as permitted. Removing a saved task record
    /// does not create or send an OSC 7501 'done' report.
    pub fn removeWorkingAndBlocked(self: *Records, alloc: std.mem.Allocator) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            switch (self.items.items[index].state) {
                .working, .blocked => self.removeAt(alloc, index),
                else => index += 1,
            }
        }
    }

    /// Write OSC 7501 messages that restore saved Program Status task records
    /// in a reconnecting terminal. Write nothing if an update could not be saved.
    /// Buffer this output before sending it so a write failure cannot send
    /// only part of the saved task list.
    pub fn writeReplay(self: *const Records, writer: *std.Io.Writer) !void {
        if (self.has_unsaved_update) {
            // Some OSC 7501 task records may be missing. Do not replace the
            // client's Program Status records with a list we know is incomplete.
            return;
        }

        // Send OSC 7501 'clear' to remove the client's old Program Status records
        // before restoring ours. Do this even when we have no saved task records.
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
    /// "A parent does not have to exist. Terminals MUST use this relationship
    /// for clearing (see States) and app inheritance (see Keys), and MAY use
    /// it for grouping. It means nothing else."
    /// www.superlogical.com/rex/docs/build/program-status#records-and-ids
    ///
    /// An ID of 'build' removes 'build' and 'build/test', but leaves 'builder' alone.
    fn removeTaskAndChildren(self: *Records, alloc: std.mem.Allocator, id: ?[]const u8) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            var matches = true;
            if (id) |task_id| {
                matches = false;
                if (self.items.items[index].readOption(.id)) |report_id| {
                    const same_task = std.mem.eql(u8, task_id, report_id);
                    // "build/test is a child of build"
                    // www.superlogical.com/rex/docs/build/program-status#records-and-ids
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
        if (first_id == null) return second_id == null;
        return second_id != null and std.mem.eql(u8, first_id.?, second_id.?);
    }
};

test "program status preserves existing records on allocation failure" {
    var records: Records = .{};
    defer records.deinit(std.testing.allocator);
    try records.updateFromReport(std.testing.allocator, .{ .state = .done, .data = "state=done:app=test" });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, records.updateFromReport(failing.allocator(), .{
        .state = .blocked,
        .data = "state=blocked",
    }));
    try std.testing.expectEqual(.done, records.get(null).?.state);
    try std.testing.expectEqualStrings("test", records.get(null).?.readOption(.app).?);
}

test "program status failed record capacity growth disables replay without leaking copied bytes" {
    var records: Records = .{};
    defer records.deinit(std.testing.allocator);
    // Copying the OSC 7501 report succeeds, then growing the saved task list fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, records.updateFromReport(failing.allocator(), .{ .state = .working, .data = "state=working" }));
    try std.testing.expectEqual(@as(usize, 0), records.items.items.len);
    try std.testing.expect(records.has_unsaved_update);
}

test "program status evicts the least recently updated record" {
    const alloc = std.testing.allocator;
    var records: Records = .{};
    defer records.deinit(alloc);
    var buf: [64]u8 = undefined;
    for (0..Records.max_records) |i| {
        try records.updateFromReport(alloc, .{
            .state = .working,
            .data = try std.fmt.bufPrint(&buf, "state=working:id=task-{d}", .{i}),
        });
    }
    // Refreshing 'task-0' protects it. Adding 'task-256' removes 'task-1' instead.
    try records.updateFromReport(alloc, .{ .state = .blocked, .data = "state=blocked:id=task-0" });
    try records.updateFromReport(alloc, .{ .state = .working, .data = "state=working:id=task-256" });
    try std.testing.expectEqual(@as(usize, Records.max_records), records.items.items.len);
    try std.testing.expect(records.get("task-0") != null);
    try std.testing.expect(records.get("task-1") == null);
    try std.testing.expect(records.get("task-256") != null);
}
