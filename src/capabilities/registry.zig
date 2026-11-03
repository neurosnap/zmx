//! The capability registry assembles the capabilities a new daemon will run.
//! The command line uses it to look up optional names. Configuration combines
//! those definitions, or definitions supplied directly by libzmx callers, with
//! the registered always-active capabilities. Names identify compiled Zig modules.
const std = @import("std");
const api = @import("capability-api");
const runtime = @import("capability-runtime");
const definitions = @import("definitions.zig");

const catalog = [_]api.Definition{ definitions.working_directory, definitions.program_status };

/// Look up comma-separated optional capability names for the command line.
/// The result contains only the requested optional definitions in request order.
/// Configuration adds always-active definitions later, using 'select'. Unknown
/// names, repeated names, and names already marked always-active are rejected.
/// Empty input requests no optional capabilities. The caller owns the slice.
pub fn resolveOptional(alloc: std.mem.Allocator, names: []const u8) ![]const api.Definition {
    return lookup(alloc, &catalog, names);
}

/// Assemble the daemon's full capability list from explicit optional definitions.
/// Always-active definitions come first in registry order, followed by the supplied
/// definitions in order. Custom modules need not be registered, but names must be
/// unique across the full list. The caller owns the returned slice.
pub fn select(alloc: std.mem.Allocator, optional: []const api.Definition) ![]const api.Definition {
    return assemble(alloc, &catalog, optional);
}

fn lookup(alloc: std.mem.Allocator, available: []const api.Definition, names: []const u8) ![]const api.Definition {
    var result: std.ArrayList(api.Definition) = .empty;
    errdefer result.deinit(alloc);

    if (names.len != 0) {
        var split = std.mem.splitScalar(u8, names, ',');
        while (split.next()) |name| {
            const definition = for (available) |candidate| {
                if (std.mem.eql(u8, name, candidate.name)) {
                    break candidate;
                }
            } else {
                std.log.warn("unknown capability '{s}'", .{name});
                return error.UnknownCapability;
            };

            if (definition.always_active) {
                return error.DuplicateCapability;
            }

            try result.append(alloc, definition);
        }
    }

    try runtime.validate(result.items);
    return try result.toOwnedSlice(alloc);
}

fn assemble(alloc: std.mem.Allocator, available: []const api.Definition, optional: []const api.Definition) ![]const api.Definition {
    var result: std.ArrayList(api.Definition) = .empty;
    errdefer result.deinit(alloc);

    // Required behavior belongs to the daemon, regardless of which caller
    // supplied the optional additions. Keep its order and ownership stable.
    for (available) |definition| {
        if (definition.always_active) {
            try result.append(alloc, definition);
        }
    }

    try result.appendSlice(alloc, optional);
    try runtime.validate(result.items);
    return try result.toOwnedSlice(alloc);
}

test "optional capability names preserve required behavior and reject invalid selections" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "missing", "osc7501,missing", ",osc7501", "osc7501,", " osc7501" }) |names| {
        try std.testing.expectError(error.UnknownCapability, resolveOptional(alloc, names));
    }

    for ([_][]const u8{ "osc7501,osc7501", "osc7", "osc7,osc7501" }) |names| {
        try std.testing.expectError(error.DuplicateCapability, resolveOptional(alloc, names));
    }

    const empty = try resolveOptional(alloc, "");
    defer alloc.free(empty);

    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const enabled = try resolveOptional(alloc, "osc7501");
    defer alloc.free(enabled);

    try std.testing.expectEqual(@as(usize, 1), enabled.len);
    try std.testing.expectEqualStrings("osc7501", enabled[0].name);
    try std.testing.checkAllAllocationFailures(alloc, resolveConfiguration, .{});
    try std.testing.checkAllAllocationFailures(alloc, selectConfiguration, .{});
}

test "selection derives required definitions from flags and preserves optional order" {
    const alloc = std.testing.allocator;
    var first = definitions.working_directory;
    first.name = "required-first";
    var second = first;
    second.name = "required-second";
    var optional_a = definitions.program_status;
    optional_a.name = "optional-a";
    var optional_b = optional_a;
    optional_b.name = "optional-b";
    const available = [_]api.Definition{ optional_a, first, optional_b, second };

    const requested = try lookup(alloc, &available, "optional-b,optional-a");
    defer alloc.free(requested);

    const named = try assemble(alloc, &available, requested);
    defer alloc.free(named);

    // A library can supply a compiled module absent from the named catalog.
    var custom = optional_a;
    custom.name = "custom";
    const supplied = try assemble(alloc, &available, &.{ custom, optional_b, optional_a });
    defer alloc.free(supplied);

    for ([_][]const api.Definition{ named, supplied }) |selected| {
        try std.testing.expectEqualStrings("required-first", selected[0].name);
        try std.testing.expectEqualStrings("required-second", selected[1].name);
        try std.testing.expectEqualStrings("optional-b", selected[selected.len - 2].name);
        try std.testing.expectEqualStrings("optional-a", selected[selected.len - 1].name);
    }

    try std.testing.expectEqual(@as(usize, 4), named.len);
    try std.testing.expectEqual(@as(usize, 5), supplied.len);
    try std.testing.expectEqualStrings("custom", supplied[2].name);
    custom.name = first.name;
    try std.testing.expectError(error.DuplicateCapability, assemble(alloc, &available, &.{custom}));
    try std.testing.expectError(error.DuplicateCapability, select(alloc, &.{ definitions.program_status, definitions.program_status }));
}

fn resolveConfiguration(allocator: std.mem.Allocator) !void {
    const optional = try resolveOptional(allocator, "osc7501");
    defer allocator.free(optional);

    const result = try select(allocator, optional);
    defer allocator.free(result);
}

fn selectConfiguration(allocator: std.mem.Allocator) !void {
    const result = try select(allocator, &.{definitions.program_status});
    defer allocator.free(result);
}
