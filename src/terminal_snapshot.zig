const std = @import("std");
const ghostty = @import("ghostty-vt");
const sgr = @import("sgr.zig");

/// Extract UTF-8 text content from a cell, including multi-codepoint graphemes
fn extractCellText(pin: ghostty.Pin, cell: *const ghostty.Cell, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    // Skip empty cells and spacer cells
    if (cell.isEmpty()) return;
    if (cell.wide == .spacer_tail or cell.wide == .spacer_head) return;

    // Get the first codepoint
    const cp = cell.codepoint();
    if (cp == 0) return; // Empty cell

    // Encode first codepoint to UTF-8
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return;
    try buf.appendSlice(allocator, utf8_buf[0..len]);

    // If this is a multi-codepoint grapheme, encode the rest
    if (cell.hasGrapheme()) {
        if (pin.grapheme(cell)) |codepoints| {
            for (codepoints) |extra_cp| {
                const extra_len = std.unicode.utf8Encode(extra_cp, &utf8_buf) catch continue;
                try buf.appendSlice(allocator, utf8_buf[0..extra_len]);
            }
        }
    }
}

/// Render the current terminal viewport state as text with proper escape sequences
/// Returns owned slice that must be freed by caller
pub fn render(vt: *ghostty.Terminal, allocator: std.mem.Allocator) ![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, 4096);
    errdefer output.deinit(allocator);

    // Prepare terminal: hide cursor, reset scroll region, reset SGR, clear screen, home cursor
    try output.appendSlice(allocator, "\x1b[?25l"); // Hide cursor
    try output.appendSlice(allocator, "\x1b[r"); // Reset scroll region
    try output.appendSlice(allocator, "\x1b[0m"); // Reset SGR (colors/styles)
    try output.appendSlice(allocator, "\x1b[2J"); // Clear entire screen
    try output.appendSlice(allocator, "\x1b[H"); // Home cursor (1,1)

    // Get the terminal's page list
    const pages = &vt.screen.pages;

    // Create row iterator for active viewport
    var row_it = pages.rowIterator(.right_down, .{ .active = .{} }, null);

    // Iterate through viewport rows
    var row_idx: usize = 0;
    while (row_it.next()) |pin| : (row_idx += 1) {
        // Position cursor at the start of this row (1-based indexing)
        const row_num = row_idx + 1;
        try std.fmt.format(output.writer(allocator), "\x1b[{d};1H", .{row_num});

        // Clear the entire line to avoid stale content
        try output.appendSlice(allocator, "\x1b[2K");

        // Get row and cell data from pin
        const rac = pin.rowAndCell();
        const row = rac.row;
        const page = &pin.node.data;
        const cells = page.getCells(row);

        // Track style changes to emit SGR sequences
        var last_style = ghostty.Style{}; // Start with default style

        // Extract text from each cell in the row
        var col_idx: usize = 0;
        while (col_idx < cells.len) : (col_idx += 1) {
            const cell = &cells[col_idx];

            // Skip spacer cells (already handled by extractCellText, but we still need to skip the iteration)
            if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;

            // Create a pin for this specific cell to access graphemes
            const cell_pin = ghostty.Pin{
                .node = pin.node,
                .y = pin.y,
                .x = @intCast(col_idx),
            };

            // Get the style for this cell
            const cell_style = cell_pin.style(cell);

            // If style changed, emit SGR sequence
            if (!cell_style.eql(last_style)) {
                const sgr_seq = try sgr.emitStyleChange(allocator, last_style, cell_style);
                defer allocator.free(sgr_seq);
                try output.appendSlice(allocator, sgr_seq);
                last_style = cell_style;
            }

            try extractCellText(cell_pin, cell, &output, allocator);

            // If this is a wide character, skip the next cell (spacer_tail)
            if (cell.wide == .wide) {
                col_idx += 1; // Skip the spacer cell that follows
            }
        }

        // Reset style at end of row to avoid style bleeding
        if (!last_style.default()) {
            try output.appendSlice(allocator, "\x1b[0m");
        }
    }

    // Restore cursor position from terminal state
    const cursor = vt.screen.cursor;
    const cursor_row = cursor.y + 1; // Convert to 1-based
    var cursor_col: u16 = @intCast(cursor.x + 1); // Convert to 1-based

    // If cursor is at x=0, try to find the actual end of content on that row
    // This handles race conditions where the cursor position wasn't updated yet
    if (cursor.x == 0) {
        const cursor_pin = pages.pin(.{ .active = .{ .x = 0, .y = cursor.y } });
        if (cursor_pin) |cpin| {
            const crac = cpin.rowAndCell();
            const crow = crac.row;
            const cpage = &cpin.node.data;
            const ccells = cpage.getCells(crow);

            // Find the last non-empty cell (including spaces)
            var last_col: usize = 0;
            var col: usize = 0;
            while (col < ccells.len) : (col += 1) {
                const cell = &ccells[col];
                if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
                const cp = cell.codepoint();
                if (cp != 0) { // Include spaces, just not null
                    last_col = col;
                }
                if (cell.wide == .wide) col += 1;
            }

            // If we found content, position cursor after the last character
            if (last_col > 0) {
                cursor_col = @intCast(last_col + 2); // +1 for after character, +1 for 1-based
            }
        }
    }

    try std.fmt.format(output.writer(allocator), "\x1b[{d};{d}H", .{ cursor_row, cursor_col });

    // Show cursor
    try output.appendSlice(allocator, "\x1b[?25h");

    return output.toOwnedSlice(allocator);
}

test "render: rowIterator viewport iteration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a simple terminal
    var vt = try ghostty.Terminal.init(allocator, 80, 24, 100);
    defer vt.deinit(allocator);

    // Write some content
    try vt.print('H');
    try vt.print('e');
    try vt.print('l');
    try vt.print('l');
    try vt.print('o');

    // Test that we can iterate through viewport using rowIterator
    const pages = &vt.screen.pages;
    var row_it = pages.rowIterator(.right_down, .{ .active = .{} }, null);

    var row_count: usize = 0;
    while (row_it.next()) |pin| : (row_count += 1) {
        const rac = pin.rowAndCell();
        _ = rac; // Just verify we can access row and cell
    }

    try testing.expectEqual(pages.rows, row_count);
}

test "extractCellText: single codepoint" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vt = try ghostty.Terminal.init(allocator, 80, 24, 100);
    defer vt.deinit(allocator);

    // Write ASCII text
    try vt.print('A');
    try vt.print('B');
    try vt.print('C');

    // Get the first cell
    const pages = &vt.screen.pages;
    const pin = pages.pin(.{ .active = .{} }).?;
    const rac = pin.rowAndCell();
    const page = &pin.node.data;
    const cells = page.getCells(rac.row);

    // Extract text from first 3 cells
    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer buf.deinit(allocator);

    for (cells[0..3], 0..) |*cell, col_idx| {
        const cell_pin = ghostty.Pin{
            .node = pin.node,
            .y = pin.y,
            .x = @intCast(col_idx),
        };
        try extractCellText(cell_pin, cell, &buf, allocator);
    }

    try testing.expectEqualStrings("ABC", buf.items);
}

test "extractCellText: multi-codepoint grapheme (emoji)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vt = try ghostty.Terminal.init(allocator, 80, 24, 100);
    defer vt.deinit(allocator);

    // Write an emoji with skin tone modifier (multi-codepoint grapheme)
    // 👋 (waving hand) + skin tone modifier
    try vt.print(0x1F44B); // 👋
    try vt.print(0x1F3FB); // light skin tone

    const pages = &vt.screen.pages;
    const pin = pages.pin(.{ .active = .{} }).?;
    const rac = pin.rowAndCell();
    const page = &pin.node.data;
    const cells = page.getCells(rac.row);

    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer buf.deinit(allocator);

    try extractCellText(pin, &cells[0], &buf, allocator);

    // Should have both codepoints encoded as UTF-8
    try testing.expect(buf.items.len > 4); // At least 2 multi-byte UTF-8 sequences
}

test "wide character handling: skip spacer cells" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vt = try ghostty.Terminal.init(allocator, 80, 24, 100);
    defer vt.deinit(allocator);

    // Write wide character (emoji) followed by ASCII
    try vt.print(0x1F44B); // 👋 (wide, takes 2 cells)
    try vt.print('A');
    try vt.print('B');

    // Render the terminal
    const result = try render(&vt, allocator);
    defer allocator.free(result);

    // Should have emoji + AB + newline (not emoji + A + B with drift)
    // The emoji is UTF-8 encoded, so we just check we have content
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "AB") != null);
}
