const std = @import("std");
const ghostty = @import("ghostty-vt");

// Handler for processing VT sequences
const VTHandler = struct {
    terminal: *ghostty.Terminal,
    pty_master_fd: std.posix.fd_t,

    pub fn print(self: *VTHandler, cp: u21) !void {
        try self.terminal.print(cp);
    }

    pub fn setMode(self: *VTHandler, mode: ghostty.Mode, enabled: bool) !void {
        self.terminal.modes.set(mode, enabled);
        std.debug.print("Mode changed: {s} = {}\n", .{ @tagName(mode), enabled });
    }

    // SGR attributes (colors, bold, italic, etc.)
    pub fn setAttribute(self: *VTHandler, attr: ghostty.Attribute) !void {
        try self.terminal.setAttribute(attr);
    }

    // Cursor positioning
    pub fn setCursorPos(self: *VTHandler, row: usize, col: usize) !void {
        self.terminal.setCursorPos(row, col);
    }

    pub fn setCursorRow(self: *VTHandler, row: usize) !void {
        self.terminal.setCursorPos(row, self.terminal.screen.cursor.x);
    }

    pub fn setCursorCol(self: *VTHandler, col: usize) !void {
        self.terminal.setCursorPos(self.terminal.screen.cursor.y, col);
    }

    // Screen/line erasing
    pub fn eraseDisplay(self: *VTHandler, mode: ghostty.EraseDisplay, protected: bool) !void {
        self.terminal.eraseDisplay(mode, protected);
    }

    pub fn eraseLine(self: *VTHandler, mode: ghostty.EraseLine, protected: bool) !void {
        self.terminal.eraseLine(mode, protected);
    }

    // Scroll regions
    pub fn setTopAndBottomMargin(self: *VTHandler, top: usize, bottom: usize) !void {
        self.terminal.setTopAndBottomMargin(top, bottom);
    }

    // Cursor save/restore
    pub fn saveCursor(self: *VTHandler) !void {
        self.terminal.saveCursor();
    }

    pub fn restoreCursor(self: *VTHandler) !void {
        try self.terminal.restoreCursor();
    }

    // Tab stops
    pub fn tabSet(self: *VTHandler) !void {
        self.terminal.tabSet();
    }

    pub fn tabClear(self: *VTHandler, cmd: ghostty.TabClear) !void {
        self.terminal.tabClear(cmd);
    }

    pub fn tabReset(self: *VTHandler) !void {
        self.terminal.tabReset();
    }

    // Cursor movement (relative)
    pub fn cursorUp(self: *VTHandler, count: usize) !void {
        self.terminal.cursorUp(count);
    }

    pub fn cursorDown(self: *VTHandler, count: usize) !void {
        self.terminal.cursorDown(count);
    }

    pub fn cursorForward(self: *VTHandler, count: usize) !void {
        self.terminal.cursorRight(count);
    }

    pub fn cursorBack(self: *VTHandler, count: usize) !void {
        self.terminal.cursorLeft(count);
    }

    pub fn setCursorColRelative(self: *VTHandler, count: usize) !void {
        const new_col = self.terminal.screen.cursor.x + count;
        self.terminal.setCursorPos(self.terminal.screen.cursor.y, new_col);
    }

    pub fn setCursorRowRelative(self: *VTHandler, count: usize) !void {
        const new_row = self.terminal.screen.cursor.y + count;
        self.terminal.setCursorPos(new_row, self.terminal.screen.cursor.x);
    }

    // Special movement (ESC sequences)
    pub fn index(self: *VTHandler) !void {
        try self.terminal.index();
    }

    pub fn reverseIndex(self: *VTHandler) !void {
        self.terminal.reverseIndex();
    }

    pub fn nextLine(self: *VTHandler) !void {
        try self.terminal.linefeed();
        self.terminal.carriageReturn();
    }

    pub fn prevLine(self: *VTHandler) !void {
        self.terminal.reverseIndex();
        self.terminal.carriageReturn();
    }

    // Line/char editing
    pub fn insertLines(self: *VTHandler, count: usize) !void {
        self.terminal.insertLines(count);
    }

    pub fn deleteLines(self: *VTHandler, count: usize) !void {
        self.terminal.deleteLines(count);
    }

    pub fn deleteChars(self: *VTHandler, count: usize) !void {
        self.terminal.deleteChars(count);
    }

    pub fn eraseChars(self: *VTHandler, count: usize) !void {
        self.terminal.eraseChars(count);
    }

    pub fn scrollUp(self: *VTHandler, count: usize) !void {
        self.terminal.scrollUp(count);
    }

    pub fn scrollDown(self: *VTHandler, count: usize) !void {
        self.terminal.scrollDown(count);
    }

    // Basic control characters
    pub fn carriageReturn(self: *VTHandler) !void {
        self.terminal.carriageReturn();
    }

    pub fn linefeed(self: *VTHandler) !void {
        try self.terminal.linefeed();
    }

    pub fn backspace(self: *VTHandler) !void {
        self.terminal.backspace();
    }

    pub fn horizontalTab(self: *VTHandler, count: usize) !void {
        _ = count; // stream always passes 1
        try self.terminal.horizontalTab();
    }

    pub fn horizontalTabBack(self: *VTHandler, count: usize) !void {
        _ = count; // stream always passes 1
        try self.terminal.horizontalTabBack();
    }

    pub fn bell(self: *VTHandler) !void {
        _ = self;
        // Ignore bell in daemon context - no UI to notify
    }

    pub fn deviceAttributes(
        self: *VTHandler,
        req: ghostty.DeviceAttributeReq,
        da_params: []const u16,
    ) !void {
        _ = self;
        _ = req;
        _ = da_params;

        // const response = getDeviceAttributeResponse(req) orelse return;

        // _ = posix.write(self.pty_master_fd, response) catch |err| {
        //     std.debug.print("Error writing DA response to PTY: {s}\n", .{@errorName(err)});
        // };

        // std.debug.print("Responded to DA query ({s}) with {s}\n", .{ @tagName(req), response });
    }
};
