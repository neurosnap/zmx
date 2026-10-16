//! Test-only rendered-screen oracle using the same terminal engine as zmx.
const std = @import("std");
const ghostty = @import("ghostty-vt");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.ExpectedFileColsRows;
    const cols = try std.fmt.parseInt(u16, args.next() orelse return error.ExpectedFileColsRows, 10);
    const rows = try std.fmt.parseInt(u16, args.next() orelse return error.ExpectedFileColsRows, 10);
    if (cols == 0 or rows == 0 or args.next() != null) return error.InvalidDimensions;

    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(16 * 1024 * 1024 + 1));
    defer init.gpa.free(input);
    if (input.len > 16 * 1024 * 1024) return error.StreamTooLong;
    var term = try ghostty.Terminal.init(init.io, init.gpa, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_lines = 10_000,
        .max_scrollback_bytes = null,
    });
    defer term.deinit(init.gpa);
    {
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice(input);
    }
    // plainString is the active viewport, with physical row breaks and no
    // styling; it deliberately excludes scrollback. Cursor coordinates are 0-based.
    const text = try term.plainString(init.gpa);
    defer init.gpa.free(text);
    var scrollback: std.Io.Writer.Allocating = .init(init.gpa);
    defer scrollback.deinit();
    const pages = &term.screens.active.pages;
    const screen_top = pages.getTopLeft(.screen);
    const active_top = pages.getTopLeft(.active);
    if (!screen_top.eql(active_top)) {
        if (active_top.up(1)) |last_row| {
            var bottom = last_row;
            bottom.x = cols - 1;
            try term.screens.active.dumpString(&scrollback.writer, .{
                .tl = screen_top,
                .br = bottom,
                .unwrap = false,
            });
        }
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try std.json.Stringify.value(.{
        .text = text,
        .scrollback_text = scrollback.written(),
        .cursor_x = term.screens.active.cursor.x,
        .cursor_y = term.screens.active.cursor.y,
        .alternate = term.screens.active_key == .alternate,
    }, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
