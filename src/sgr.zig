const std = @import("std");
const ghostty = @import("ghostty-vt");

/// Helper functions for generating ANSI SGR (Select Graphic Rendition) escape sequences
/// from ghostty-vt Style objects. Used to restore terminal styling when reattaching to sessions.
/// Generate SGR sequence to change from old_style to new_style.
/// Emits minimal SGR codes to reduce output size.
/// Returns owned slice that caller must free.
pub fn emitStyleChange(
    allocator: std.mem.Allocator,
    old_style: ghostty.Style,
    new_style: ghostty.Style,
) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);

    // If new style is default, emit reset
    if (new_style.default()) {
        try buf.appendSlice(allocator, "\x1b[0m");
        return buf.toOwnedSlice(allocator);
    }

    // Start escape sequence
    try buf.appendSlice(allocator, "\x1b[");
    var first = true;

    // Helper to add separator
    const addSep = struct {
        fn call(b: *std.ArrayList(u8), alloc: std.mem.Allocator, is_first: *bool) !void {
            if (!is_first.*) {
                try b.append(alloc, ';');
            }
            is_first.* = false;
        }
    }.call;

    // Bold
    if (new_style.flags.bold != old_style.flags.bold) {
        try addSep(&buf, allocator, &first);
        if (new_style.flags.bold) {
            try buf.append(allocator, '1');
        } else {
            try buf.appendSlice(allocator, "22");
        }
    }

    // Faint
    if (new_style.flags.faint != old_style.flags.faint) {
        try addSep(&buf, allocator, &first);
        if (new_style.flags.faint) {
            try buf.append(allocator, '2');
        } else {
            try buf.appendSlice(allocator, "22");
        }
    }

    // Italic
    if (new_style.flags.italic != old_style.flags.italic) {
        try addSep(&buf, allocator, &first);
        if (new_style.flags.italic) {
            try buf.append(allocator, '3');
        } else {
            try buf.appendSlice(allocator, "23");
        }
    }

    // Underline
    if (!std.meta.eql(new_style.flags.underline, old_style.flags.underline)) {
        try addSep(&buf, allocator, &first);
        switch (new_style.flags.underline) {
            .none => try buf.appendSlice(allocator, "24"),
            .single => try buf.append(allocator, '4'),
            .double => try buf.appendSlice(allocator, "21"),
            .curly => try buf.appendSlice(allocator, "4:3"),
            .dotted => try buf.appendSlice(allocator, "4:4"),
            .dashed => try buf.appendSlice(allocator, "4:5"),
        }
    }

    // Blink
    if (new_style.flags.blink != old_style.flags.blink) {
        try addSep(&buf, allocator, &first);
        if (new_style.flags.blink) {
            try buf.append(allocator, '5');
        } else {
            try buf.appendSlice(allocator, "25");
        }
    }

    // Inverse
    if (new_style.flags.inverse != old_style.flags.inverse) {
        try addSep(&buf, allocator, &first);
        if (new_style.flags.inverse) {
            try buf.append(allocator, '7');
        } else {
            try buf.appendSlice(allocator, "27");
        }
    }

    // Invisible
    if (new_style.flags.invisible != old_style.flags.invisible) {
        try addSep(&buf, allocator, &first);
        if (new_style.flags.invisible) {
            try buf.append(allocator, '8');
        } else {
            try buf.appendSlice(allocator, "28");
        }
    }

    // Strikethrough
    if (new_style.flags.strikethrough != old_style.flags.strikethrough) {
        try addSep(&buf, allocator, &first);
        if (new_style.flags.strikethrough) {
            try buf.append(allocator, '9');
        } else {
            try buf.appendSlice(allocator, "29");
        }
    }

    // Foreground color
    if (!std.meta.eql(new_style.fg_color, old_style.fg_color)) {
        try addSep(&buf, allocator, &first);
        switch (new_style.fg_color) {
            .none => try buf.appendSlice(allocator, "39"),
            .palette => |idx| {
                try buf.appendSlice(allocator, "38;5;");
                try std.fmt.format(buf.writer(allocator), "{d}", .{idx});
            },
            .rgb => |rgb| {
                try buf.appendSlice(allocator, "38;2;");
                try std.fmt.format(buf.writer(allocator), "{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b });
            },
        }
    }

    // Background color
    if (!std.meta.eql(new_style.bg_color, old_style.bg_color)) {
        try addSep(&buf, allocator, &first);
        switch (new_style.bg_color) {
            .none => try buf.appendSlice(allocator, "49"),
            .palette => |idx| {
                try buf.appendSlice(allocator, "48;5;");
                try std.fmt.format(buf.writer(allocator), "{d}", .{idx});
            },
            .rgb => |rgb| {
                try buf.appendSlice(allocator, "48;2;");
                try std.fmt.format(buf.writer(allocator), "{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b });
            },
        }
    }

    // Underline color (not all terminals support this, but emit it anyway)
    if (!std.meta.eql(new_style.underline_color, old_style.underline_color)) {
        try addSep(&buf, allocator, &first);
        switch (new_style.underline_color) {
            .none => try buf.appendSlice(allocator, "59"),
            .palette => |idx| {
                try buf.appendSlice(allocator, "58;5;");
                try std.fmt.format(buf.writer(allocator), "{d}", .{idx});
            },
            .rgb => |rgb| {
                try buf.appendSlice(allocator, "58;2;");
                try std.fmt.format(buf.writer(allocator), "{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b });
            },
        }
    }

    // End escape sequence
    try buf.append(allocator, 'm');

    // If we only added the escape opener and closer with nothing in between,
    // return empty string (no change needed)
    if (first) {
        buf.deinit(allocator);
        return allocator.dupe(u8, "");
    }

    return buf.toOwnedSlice(allocator);
}

test "emitStyleChange: default to default" {
    const allocator = std.testing.allocator;
    const result = try emitStyleChange(allocator, .{}, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "emitStyleChange: bold" {
    const allocator = std.testing.allocator;
    var new_style = ghostty.Style{};
    new_style.flags.bold = true;
    const result = try emitStyleChange(allocator, .{}, new_style);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[1m", result);
}

test "emitStyleChange: reset to default" {
    const allocator = std.testing.allocator;
    var old_style = ghostty.Style{};
    old_style.flags.bold = true;
    old_style.flags.italic = true;
    const result = try emitStyleChange(allocator, old_style, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[0m", result);
}

test "emitStyleChange: palette color" {
    const allocator = std.testing.allocator;
    var new_style = ghostty.Style{};
    new_style.fg_color = .{ .palette = 196 }; // red
    const result = try emitStyleChange(allocator, .{}, new_style);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[38;5;196m", result);
}

test "emitStyleChange: rgb color" {
    const allocator = std.testing.allocator;
    var new_style = ghostty.Style{};
    new_style.bg_color = .{ .rgb = .{ .r = 255, .g = 128, .b = 64 } };
    const result = try emitStyleChange(allocator, .{}, new_style);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[48;2;255;128;64m", result);
}

test "emitStyleChange: multiple attributes" {
    const allocator = std.testing.allocator;
    var new_style = ghostty.Style{};
    new_style.flags.bold = true;
    new_style.flags.italic = true;
    new_style.fg_color = .{ .palette = 10 };
    const result = try emitStyleChange(allocator, .{}, new_style);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[1;3;38;5;10m", result);
}
