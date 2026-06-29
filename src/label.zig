const std = @import("std");

pub const LabelError = error{
    LabelKeyEmpty,
    LabelKeyInvalidChar,
    LabelValueInvalidChar,
    LabelKeyReservedName,
};

const reserved_keys = [_][]const u8{ "name", "start_dir", "cmd" };

fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9');
}

pub fn assertLabel(key: []const u8, value: []const u8) LabelError!void {
    if (key.len == 0) {
        return LabelError.LabelKeyEmpty;
    }

    for (reserved_keys) |rk| {
        if (std.mem.eql(u8, key, rk)) return error.LabelKeyReservedName;
    }

    for (key) |ch| {
        if (!isAlnum(ch) and ch != '-' and ch != '_' and ch != '.') {
            return LabelError.LabelKeyInvalidChar;
        }
    }

    for (value) |ch| {
        if (!isAlnum(ch) and ch != '-' and ch != '_' and ch != '.') {
            return LabelError.LabelValueInvalidChar;
        }
    }
}

pub fn labelsToU8(alloc: std.mem.Allocator, labels: std.StringHashMapUnmanaged([]u8)) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(alloc);

    var it = labels.iterator();
    while (it.next()) |entry| {
        try keys.append(alloc, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var idx: usize = 1;
    for (keys.items) |key| {
        defer idx += 1;
        const value = labels.get(key).?;
        try out.appendSlice(alloc, key);
        try out.append(alloc, '=');
        try out.appendSlice(alloc, value);
        if (idx < keys.items.len) {
            try out.append(alloc, ' ');
        }
    }
    return out.toOwnedSlice(alloc);
}

pub const LabelIterator = struct {
    labels: []const u8,
    idx: usize = 0,

    const LabelKeyValue = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn init(labels: []const u8) LabelIterator {
        return .{
            .labels = labels,
        };
    }

    pub fn next(self: *LabelIterator) ?LabelKeyValue {
        const labels = self.labels;
        while (self.idx < labels.len) {
            var eql_idx = self.idx;
            // scan to '=' char
            while (eql_idx < labels.len and labels[eql_idx] != '=') eql_idx += 1;
            if (eql_idx == labels.len) break;

            var space_idx = eql_idx + 1;
            // scan to ' ' char
            while (space_idx < labels.len and labels[space_idx] != ' ') space_idx += 1;

            const kv = LabelKeyValue{
                .key = labels[self.idx..eql_idx],
                .value = labels[eql_idx + 1 .. space_idx],
            };
            // move the pointer so next() will start where it left off
            self.idx = if (space_idx < labels.len) space_idx + 1 else labels.len;
            return kv;
        }

        return null;
    }
};

pub fn getLabelValueFromPairs(single_kv: []const u8, labels: []const u8) error{LabelKeyNotFound}![]const u8 {
    var iter = LabelIterator.init(labels);
    while (iter.next()) |kv| {
        if (std.mem.eql(u8, single_kv, kv.key)) {
            return kv.value;
        }
    }
    return error.LabelKeyNotFound;
}

test "getLabelValueFromPairs" {
    try std.testing.expect(std.mem.eql(u8, "zmx", try getLabelValueFromPairs("project", "project=zmx env=prd")));
    try std.testing.expect(std.mem.eql(u8, "zmx", try getLabelValueFromPairs("project", "env=prd status=done project=zmx")));
    try std.testing.expectError(error.LabelKeyNotFound, getLabelValueFromPairs("sha", "env=prd status=done project=zmx"));
}

test "assertLabel" {
    try assertLabel("key", "");
    try assertLabel("1337", "");
    try assertLabel("key.key_key-key", "");
    try std.testing.expectError(error.LabelKeyEmpty, assertLabel("", "value"));
    try std.testing.expectError(error.LabelKeyInvalidChar, assertLabel("key key", ""));
    try std.testing.expectError(error.LabelKeyInvalidChar, assertLabel("key:key", ""));
    try std.testing.expectError(error.LabelKeyInvalidChar, assertLabel("key/key", ""));

    try assertLabel("key", "");
    try assertLabel("key", "1337");
    try assertLabel("key", "value");
    try assertLabel("key", "value.value_value-value");
    try std.testing.expectError(error.LabelValueInvalidChar, assertLabel("key", "value value"));
    try std.testing.expectError(error.LabelValueInvalidChar, assertLabel("key", "value:value"));
    try std.testing.expectError(error.LabelValueInvalidChar, assertLabel("key", "value/value"));

    try std.testing.expectError(error.LabelKeyReservedName, assertLabel("name", "dev"));
    try std.testing.expectError(error.LabelKeyReservedName, assertLabel("start_dir", "dev"));
    try std.testing.expectError(error.LabelKeyReservedName, assertLabel("cmd", "dev"));
}
