const std = @import("std");
const ghostty = @import("ghostty-vt");
const sgr = @import("sgr.zig");

/// Terminal snapshot rendering for session persistence.
///
/// This module renders the current viewport state (text, colors, cursor position)
/// as a sequence of ANSI escape codes that can be sent to a client to restore
/// the visual terminal state when reattaching to a session.
///
/// Current implementation: Viewport-only rendering
/// - Renders only the visible active viewport (not full scrollback)
/// - Includes text content, SGR attributes (colors, bold, italic, etc.), and cursor position
/// - Handles single/multi-codepoint graphemes and wide characters correctly
///
/// Future work (see bd-10, bd-11):
/// - Full scrollback history rendering (see bd-10)
/// - Alternate screen buffer detection and handling (see bd-11)
/// - Mode restoration (bracketed paste, origin mode, etc.)
/// - Hyperlink reconstitution (OSC 8 sequences)
/// - Handling buffered/unprocessed PTY data (see bd-11)
///
/// Why viewport-only?
/// - Avoids payload bloat on reattach (megabytes for large scrollback)
/// - Prevents scrollback duplication in client terminal on multiple reattaches
/// - Faster rendering and simpler implementation
/// - Server owns the "true" scrollback, can add browsing features later
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

    // Check if we're on alternate screen (vim, less, etc.)
    const is_alt_screen = vt.active_screen == .alternate;

    // Prepare terminal: hide cursor, reset scroll region, reset SGR
    try output.appendSlice(allocator, "\x1b[?25l"); // Hide cursor
    try output.appendSlice(allocator, "\x1b[r"); // Reset scroll region
    try output.appendSlice(allocator, "\x1b[0m"); // Reset SGR (colors/styles)

    // If alternate screen, switch to it before rendering
    if (is_alt_screen) {
        try output.appendSlice(allocator, "\x1b[?1049h"); // Enter alt screen (save cursor, switch, clear)
        try output.appendSlice(allocator, "\x1b[2J"); // Clear alt screen explicitly
        try output.appendSlice(allocator, "\x1b[H"); // Home cursor
    } else {
        try output.appendSlice(allocator, "\x1b[2J"); // Clear entire screen
        try output.appendSlice(allocator, "\x1b[H"); // Home cursor (1,1)
    }

    // Get the terminal's page list (for active screen)
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

    // Restore scroll margins from terminal state (critical for vim scrolling)
    const scroll = vt.scrolling_region;
    const is_full_tb = (scroll.top == 0 and scroll.bottom == vt.rows - 1);

    if (!is_full_tb) {
        // Restore top/bottom margins
        const top = scroll.top + 1; // Convert to 1-based
        const bottom = scroll.bottom + 1; // Convert to 1-based
        try std.fmt.format(output.writer(allocator), "\x1b[{d};{d}r", .{ top, bottom });
    }

    // Restore terminal modes (critical for vim and other apps)
    // These modes affect cursor positioning, scrolling, and input behavior

    // Origin mode (?6 / DECOM): cursor positioning relative to margins
    const origin = vt.modes.get(.origin);
    if (origin) {
        try output.appendSlice(allocator, "\x1b[?6h");
    }

    // Wraparound mode (?7 / DECAWM): automatic line wrapping
    const wrap = vt.modes.get(.wraparound);
    if (!wrap) { // Default is true, so only emit if disabled
        try output.appendSlice(allocator, "\x1b[?7l");
    }

    // Reverse wraparound (?45): bidirectional wrapping
    const reverse_wrap = vt.modes.get(.reverse_wrap);
    if (reverse_wrap) {
        try output.appendSlice(allocator, "\x1b[?45h");
    }

    // Bracketed paste (?2004): paste detection
    const bracketed = vt.modes.get(.bracketed_paste);
    if (bracketed) {
        try output.appendSlice(allocator, "\x1b[?2004h");
    }

    // TODO: Restore left/right margins if enabled (need to check modes for left_right_margins)

    // Compute cursor position (may be relative to scroll margins if origin mode is on)
    // Note: The terminal stores cursor.y as absolute coordinates (0-based from top of screen)
    // When origin mode is enabled, the CSI H (cursor position) escape code expects coordinates
    // relative to the scroll region, so we need to subtract the top margin offset
    var final_cursor_row = cursor_row;
    const final_cursor_col = cursor_col;

    // If origin mode is on, cursor coordinates must be relative to the top/left margins
    if (origin and !is_full_tb) {
        final_cursor_row = (cursor_row -| (scroll.top + 1)) + 1;
        // TODO: Also handle left/right margins if left_right_margins mode is enabled
    }

    try std.fmt.format(output.writer(allocator), "\x1b[{d};{d}H", .{ final_cursor_row, final_cursor_col });

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

    // Should have emoji + AB (not emoji + A + B with drift)
    // The emoji is UTF-8 encoded, so we just check we have content
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "AB") != null);
}

test "render: colored text with SGR sequences" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vt = try ghostty.Terminal.init(allocator, 80, 24, 100);
    defer vt.deinit(allocator);

    // Set bold and write text
    try vt.setAttribute(.{ .bold = {} });
    try vt.print('B');
    try vt.print('O');
    try vt.print('L');
    try vt.print('D');

    // Reset and write normal text
    try vt.setAttribute(.{ .reset = {} });
    try vt.print(' ');
    try vt.print('n');
    try vt.print('o');
    try vt.print('r');
    try vt.print('m');

    const result = try render(&vt, allocator);
    defer allocator.free(result);

    // Should contain bold SGR (ESC[1m) and text "BOLD"
    try testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, result, "BOLD") != null);
    try testing.expect(std.mem.indexOf(u8, result, "norm") != null);
}

test "render: cursor position restoration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vt = try ghostty.Terminal.init(allocator, 80, 24, 100);
    defer vt.deinit(allocator);

    // Write some text and move cursor
    try vt.print('T');
    try vt.print('e');
    try vt.print('s');
    try vt.print('t');

    const result = try render(&vt, allocator);
    defer allocator.free(result);

    // Should contain cursor positioning sequences
    try testing.expect(std.mem.indexOf(u8, result, "\x1b[1;1H") != null); // First row positioning
    try testing.expect(std.mem.indexOf(u8, result, "\x1b[?25h") != null); // Show cursor at end
    try testing.expect(std.mem.indexOf(u8, result, "Test") != null);
}

test "render: alternate screen detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vt = try ghostty.Terminal.init(allocator, 80, 24, 100);
    defer vt.deinit(allocator);

    // Switch to alternate screen
    _ = vt.switchScreen(.alternate);

    // Write content to alt screen
    try vt.print('V');
    try vt.print('I');
    try vt.print('M');

    const result = try render(&vt, allocator);
    defer allocator.free(result);

    // Should contain alt screen switch sequence
    try testing.expect(std.mem.indexOf(u8, result, "\x1b[?1049h") != null);
    try testing.expect(std.mem.indexOf(u8, result, "VIM") != null);
}
