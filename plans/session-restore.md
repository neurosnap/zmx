# Session Restore Implementation Plan

This document outlines the plan for implementing session restore functionality in `daemon.zig` using `libghostty-vt` to preserve and restore terminal state when clients reattach to sessions.

## Overview

When a client detaches and later reattaches to a session, we need to restore the terminal to its exact visual state without replaying all historical output. We achieve this by:

1. Parsing all PTY output through libghostty-vt to maintain an up-to-date terminal grid
1. Proxying raw bytes to attached clients (no latency impact)
1. Rendering the terminal grid to ANSI on reattach

## 1. Add libghostty-vt Dependency

- Add libghostty-vt to `build.zig` and `build.zig.zon`
- Import the C bindings in `daemon.zig`
- Document the library's memory model and API surface

## 2. Extend the Session Struct

Add to `Session` struct in `daemon.zig`:

```zig
const Session = struct {
    name: []const u8,
    pty_master_fd: std.posix.fd_t,
    buffer: std.ArrayList(u8),           // Keep for backwards compat (may remove later)
    child_pid: std.posix.pid_t,
    allocator: std.mem.Allocator,
    pty_read_buffer: [4096]u8,
    created_at: i64,

    // NEW: Terminal emulator state
    vt: *c.ghostty_vt_t,                 // libghostty-vt terminal instance
    vt_grid: *c.ghostty_grid_t,          // Current terminal grid snapshot
    attached_clients: std.AutoHashMap(std.posix.fd_t, void),  // Track who's attached
};
```

## 3. Initialize Terminal Emulator on Session Creation

In `createSession()`:

- After forking PTY, initialize libghostty-vt instance
- Configure terminal size (rows, cols) - query from PTY or use defaults (e.g., 24x80)
- Configure scrollback buffer size (make this configurable, default 10,000 lines)
- Store the vt instance in the Session struct

```zig
fn createSession(allocator: std.mem.Allocator, session_name: []const u8) !*Session {
    // ... existing PTY creation code ...
    
    // Initialize libghostty-vt
    const vt = c.ghostty_vt_new(80, 24, 10000) orelse return error.VtInitFailed;
    
    session.* = .{
        // ... existing fields ...
        .vt = vt,
        .vt_grid = null,  // Will be obtained from vt as needed
        .attached_clients = std.AutoHashMap(std.posix.fd_t, void).init(allocator),
    };
    
    return session;
}
```

## 4. Parse PTY Output Through Terminal Emulator

Modify `readPtyCallback()`:

- Feed all PTY output bytes to libghostty-vt first
- Check if there are attached clients
- If clients attached: proxy raw bytes directly to them (existing behavior)
- If no clients attached: still feed to vt but don't send anywhere

```zig
fn readPtyCallback(...) xev.CallbackAction {
    const client = client_opt.?;
    const session = getSessionForClient(client) orelse return .disarm;
    
    if (read_result) |bytes_read| {
        const data = read_buffer.slice[0..bytes_read];
        
        // ALWAYS parse through libghostty-vt to maintain state
        c.ghostty_vt_write(session.vt, data.ptr, data.len);
        
        // Only proxy to clients if someone is attached
        if (session.attached_clients.count() > 0) {
            // Send raw bytes to all attached clients
            var it = session.attached_clients.keyIterator();
            while (it.next()) |client_fd| {
                const attached_client = ctx.clients.get(client_fd.*) orelse continue;
                sendPtyOutput(attached_client, data) catch |err| {
                    std.debug.print("Error sending to client {d}: {s}\n", .{client_fd.*, @errorName(err)});
                };
            }
        }
        
        return .rearm;
    }
    // ... error handling ...
}
```

## 5. Render Terminal State on Reattach

Create new function `renderTerminalSnapshot()`:

- Get current grid from libghostty-vt
- Serialize grid to ANSI escape sequences
- Send rendered output to reattaching client

```zig
fn renderTerminalSnapshot(session: *Session, allocator: std.mem.Allocator) ![]u8 {
    // Get current terminal snapshot from libghostty-vt
    const grid = c.ghostty_vt_get_grid(session.vt);
    
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    
    // Clear screen and move to home
    try output.appendSlice("\x1b[2J\x1b[H");
    
    // Render each line of the grid
    const rows = c.ghostty_grid_rows(grid);
    const cols = c.ghostty_grid_cols(grid);
    
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        // Get line data from libghostty-vt
        const line = c.ghostty_grid_get_line(grid, row);
        
        // Render cells with proper attributes (colors, bold, etc.)
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const cell = c.ghostty_line_get_cell(line, col);
            
            // Emit SGR codes for cell attributes
            try renderCellAttributes(&output, cell);
            
            // Emit the character
            const codepoint = c.ghostty_cell_get_codepoint(cell);
            try appendUtf8(&output, codepoint);
        }
        
        try output.append('\n');
    }
    
    // Reset attributes
    try output.appendSlice("\x1b[0m");
    
    return output.toOwnedSlice();
}
```

## 6. Modify handleAttachSession()

Update attach logic to:

1. Check if session exists, create if not
1. If reattaching (session already exists):
   - Render current terminal state using libghostty-vt
   - Send rendered snapshot to client
1. Add client to session's attached_clients set
1. Start proxying raw PTY output

```zig
fn handleAttachSession(ctx: *ServerContext, client: *Client, session_name: []const u8) !void {
    const session = ctx.sessions.get(session_name) orelse {
        // New session - create it
        const new_session = try createSession(ctx.allocator, session_name);
        try ctx.sessions.put(session_name, new_session);
        session = new_session;
    };
    
    // Mark client as attached
    client.attached_session = try ctx.allocator.dupe(u8, session_name);
    try session.attached_clients.put(client.fd, {});
    
    // Check if this is a reattach (session already running)
    const is_reattach = session.attached_clients.count() > 1 or session.buffer.items.len > 0;
    
    if (is_reattach) {
        // Render current terminal state and send it
        const snapshot = try renderTerminalSnapshot(session, ctx.allocator);
        defer ctx.allocator.free(snapshot);
        
        const response = try std.fmt.allocPrint(
            ctx.allocator,
            "{{\"type\":\"pty_out\",\"payload\":{{\"text\":\"{s}\"}}}}\n",
            .{snapshot},
        );
        defer ctx.allocator.free(response);
        
        _ = try posix.write(client.fd, response);
    }
    
    // Start reading from PTY if not already started
    if (!session.pty_reading) {
        try startPtyReading(ctx, session);
        session.pty_reading = true;
    }
    
    // Send attach success response
    // ... existing response code ...
}
```

## 7. Handle Window Resize Events

Add support for window size changes:

- When client sends window resize event, update libghostty-vt
- Update PTY window size with ioctl TIOCSWINSZ
- libghostty-vt will handle reflow automatically

```zig
// New message type in protocol: "window_resize"
fn handleWindowResize(client: *Client, rows: u16, cols: u16) !void {
    const session = getSessionForClient(client) orelse return error.NotAttached;
    
    // Update libghostty-vt
    c.ghostty_vt_resize(session.vt, cols, rows);
    
    // Update PTY
    var ws: c.winsize = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    _ = c.ioctl(session.pty_master_fd, c.TIOCSWINSZ, &ws);
}
```

## 8. Track Attached Clients Per Session

Modify session management:

- Remove client from session.attached_clients on detach
- On disconnect, automatically detach client
- Keep session alive even when no clients attached

```zig
fn handleDetachSession(client: *Client, session_name: []const u8, target_client_fd: ?i64) !void {
    const session = ctx.sessions.get(session_name) orelse return error.SessionNotFound;
    
    const fd_to_remove = if (target_client_fd) |fd| @intCast(fd) else client.fd;
    _ = session.attached_clients.remove(fd_to_remove);
    
    // Note: DO NOT kill session when last client detaches
    // Session continues running in background
}
```

## 9. Clean Up Terminal Emulator on Session Destroy

In session deinit:

- Free libghostty-vt resources
- Clean up attached_clients map

```zig
fn deinit(self: *Session) void {
    self.allocator.free(self.name);
    self.buffer.deinit();
    self.attached_clients.deinit();
    
    // Free libghostty-vt
    c.ghostty_vt_free(self.vt);
}
```

## 10. Configuration Options

Add configurable options (future work):

- Scrollback buffer size
- Default terminal dimensions
- Maximum grid memory usage

## Implementation Order

1. ✅ Add libghostty-vt C bindings and build integration
1. ✅ Extend Session struct with vt fields
1. ✅ Initialize vt in createSession()
1. ✅ Feed PTY output to vt in readPtyCallback()
1. ✅ Implement renderTerminalSnapshot()
1. ✅ Modify handleAttachSession() to render on reattach
1. ✅ Track attached_clients per session
1. ✅ Handle window resize events
1. ✅ Clean up vt resources in session deinit
1. ✅ Test with multiple attach/detach cycles

## Testing Strategy

- Create session, run commands, detach
- Verify PTY continues running (ps aux | grep)
- Reattach and verify terminal state is restored
- Test with various shell outputs: ls, vim, htop, long scrollback
- Test multiple clients attaching to same session
- Test window resize during detached state
