const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const Allocator = std.mem.Allocator;

pub fn dumpState(alloc: Allocator, term: *const ghostty_vt.Terminal, daemon_info: ?*const ipc.Info) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try jw.beginObject();

    // meta
    try jw.objectField("meta");
    try jw.beginObject();
    try jw.objectField("title");
    try jw.write(term.getTitle() orelse "");
    try jw.objectField("pwd");
    try jw.write(term.getPwd() orelse "");
    if (daemon_info) |info| {
        try jw.objectField("pid");
        try jw.write(info.pid);
        try jw.objectField("clients");
        try jw.write(info.clients_len);
    }
    try jw.endObject();

    // geometry
    try jw.objectField("geometry");
    try jw.beginObject();
    try jw.objectField("rows");
    try jw.write(term.rows);
    try jw.objectField("cols");
    try jw.write(term.cols);
    try jw.objectField("width_px");
    try jw.write(term.width_px);
    try jw.objectField("height_px");
    try jw.write(term.height_px);
    try jw.objectField("scrolling_region");
    try jw.beginObject();
    try jw.objectField("top");
    try jw.write(term.scrolling_region.top);
    try jw.objectField("bottom");
    try jw.write(term.scrolling_region.bottom);
    try jw.endObject();
    try jw.endObject();

    // cursor
    const active_screen = term.screens.active;
    try jw.objectField("cursor");
    try jw.beginObject();
    try jw.objectField("x");
    try jw.write(active_screen.cursor.x);
    try jw.objectField("y");
    try jw.write(active_screen.cursor.y);
    try jw.objectField("style");
    try jw.write(@tagName(active_screen.cursor.cursor_style));
    try jw.objectField("blinking");
    try jw.write(term.modes.get(.cursor_blinking));
    try jw.objectField("visible");
    try jw.write(term.modes.get(.cursor_visible));
    try jw.endObject();

    // colors
    try jw.objectField("colors");
    try jw.beginObject();
    if (term.colors.background.get()) |bg| {
        var buf: [7]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ bg.r, bg.g, bg.b }) catch unreachable;
        try jw.objectField("background");
        try jw.write(hex);
        try jw.objectField("appearance");
        const lum = @as(f32, @floatFromInt(bg.r)) * 0.299 +
            @as(f32, @floatFromInt(bg.g)) * 0.587 +
            @as(f32, @floatFromInt(bg.b)) * 0.114;
        if (lum < 128.0) {
            try jw.write("dark");
        } else {
            try jw.write("light");
        }
    } else {
        try jw.objectField("background");
        try jw.write(null);
        try jw.objectField("appearance");
        try jw.write("dark");
    }

    if (term.colors.foreground.get()) |fg| {
        var buf: [7]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ fg.r, fg.g, fg.b }) catch unreachable;
        try jw.objectField("foreground");
        try jw.write(hex);
    } else {
        try jw.objectField("foreground");
        try jw.write(null);
    }

    if (term.colors.cursor.get()) |c| {
        var buf: [7]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable;
        try jw.objectField("cursor");
        try jw.write(hex);
    } else {
        try jw.objectField("cursor");
        try jw.write(null);
    }

    // palette
    try jw.objectField("palette");
    try jw.beginArray();
    for (term.colors.palette.current) |c| {
        var buf: [7]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable;
        try jw.write(hex);
    }
    try jw.endArray();
    try jw.endObject();

    // modes
    try jw.objectField("modes");
    try jw.beginObject();
    try jw.objectField("alt_screen");
    try jw.write(term.screens.active_key == .alternate);
    inline for (std.meta.fields(ghostty_vt.modes.Mode)) |f| {
        const mode = @field(ghostty_vt.modes.Mode, f.name);
        try jw.objectField(f.name);
        try jw.write(term.modes.get(mode));
    }
    try jw.endObject();

    // mouse
    try jw.objectField("mouse");
    try jw.beginObject();
    try jw.objectField("shape");
    try jw.write(@tagName(term.mouse_shape));
    try jw.objectField("event");
    try jw.write(@tagName(term.flags.mouse_event));
    try jw.objectField("format");
    try jw.write(@tagName(term.flags.mouse_format));
    try jw.objectField("shift_capture");
    try jw.write(@tagName(term.flags.mouse_shift_capture));
    try jw.endObject();

    // keyboard
    try jw.objectField("keyboard");
    try jw.beginObject();
    const kflags = active_screen.kitty_keyboard.current();
    try jw.objectField("kitty_flags");
    try jw.write(kflags.int());
    try jw.objectField("kitty_disambiguate");
    try jw.write(kflags.disambiguate);
    try jw.objectField("kitty_report_events");
    try jw.write(kflags.report_events);
    try jw.objectField("kitty_report_alternates");
    try jw.write(kflags.report_alternates);
    try jw.objectField("kitty_report_all");
    try jw.write(kflags.report_all);
    try jw.objectField("kitty_report_associated");
    try jw.write(kflags.report_associated);
    try jw.objectField("modify_other_keys_2");
    try jw.write(term.flags.modify_other_keys_2);
    try jw.endObject();

    // buffer
    try jw.objectField("buffer");
    try jw.beginObject();
    var total_rows: usize = 0;
    var page_it = active_screen.pages.pages.first;
    while (page_it) |node| : (page_it = node.next) {
        total_rows += node.rows();
    }
    const scrollback_rows = total_rows - @min(total_rows, @as(usize, active_screen.pages.rows));
    try jw.objectField("scrollback_rows");
    try jw.write(scrollback_rows);
    try jw.objectField("has_saved_cursor");
    try jw.write(active_screen.saved_cursor != null);
    if (active_screen.saved_cursor) |sc| {
        try jw.objectField("saved_cursor");
        try jw.beginObject();
        try jw.objectField("x");
        try jw.write(sc.x);
        try jw.objectField("y");
        try jw.write(sc.y);
        try jw.objectField("origin");
        try jw.write(sc.origin);
        try jw.objectField("pending_wrap");
        try jw.write(sc.pending_wrap);
        try jw.endObject();
    }
    try jw.objectField("has_selection");
    try jw.write(active_screen.selection != null);
    try jw.objectField("protected_mode");
    try jw.write(@tagName(active_screen.protected_mode));
    try jw.endObject();

    // shell_integration
    try jw.objectField("shell_integration");
    try jw.beginObject();
    try jw.objectField("semantic_prompt");
    try jw.write(active_screen.semantic_prompt.seen);
    try jw.objectField("shell_redraws_prompt");
    try jw.write(@tagName(term.flags.shell_redraws_prompt));
    try jw.objectField("password_input");
    try jw.write(term.flags.password_input);
    try jw.endObject();

    // tabstops
    try jw.objectField("tabstops");
    try jw.beginArray();
    var col: usize = 0;
    while (col < term.cols) : (col += 1) {
        if (term.tabstops.get(col)) {
            try jw.write(col);
        }
    }
    try jw.endArray();

    // charsets
    try jw.objectField("charsets");
    try jw.beginObject();
    try jw.objectField("g0");
    try jw.write(@tagName(active_screen.charset.charsets.g0));
    try jw.objectField("g1");
    try jw.write(@tagName(active_screen.charset.charsets.g1));
    try jw.objectField("g2");
    try jw.write(@tagName(active_screen.charset.charsets.g2));
    try jw.objectField("g3");
    try jw.write(@tagName(active_screen.charset.charsets.g3));
    try jw.objectField("gl");
    try jw.write(@tagName(active_screen.charset.gl));
    try jw.objectField("gr");
    try jw.write(@tagName(active_screen.charset.gr));
    try jw.endObject();

    // flags
    try jw.objectField("flags");
    try jw.beginObject();
    try jw.objectField("focused");
    try jw.write(term.flags.focused);
    try jw.endObject();

    try jw.endObject();

    try out.writer.writeAll("\n");
    return alloc.dupe(u8, out.written());
}

test "dumpState generates valid json with terminal state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    try term.setTitle("my window");
    try term.setPwd("/home/user");

    const json = try dumpState(alloc, &term, null);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"title\": \"my window\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"pwd\": \"/home/user\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"rows\": 24") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"cols\": 80") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"cursor\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"colors\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"modes\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"keyboard\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"buffer\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"shell_integration\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tabstops\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"charsets\"") != null);
}
