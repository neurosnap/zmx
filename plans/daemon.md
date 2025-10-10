# zms daemon implementation plan

This document outlines the plan for implementing the `zmx daemon` subcommand, based on the specifications in `specs/daemon.md` and `protocol.md`.

## 1. Create `src/daemon.zig`

- Create a new file `src/daemon.zig` to house the core logic for the daemon process.

## 2. Implement Unix Socket Communication

- In `src/daemon.zig`, create and bind a Unix domain socket based on the `--socket-path` option.
- Listen for and accept incoming client connections.
- Implement a message-passing system using `std.json` for serialization and deserialization, adhering to the `protocol.md` specification.

## 3. Implement Session Management

- Define a `Session` struct to manage the state of each PTY process. This struct will include:
    - The session name.
    - The file descriptor for the PTY.
    - A buffer for the terminal output (scrollback).
    - The terminal state, managed by `libghostty-vt`.
    - A list of connected client IDs.
- Use a `std.StringHashMap(Session)` to store and manage all active sessions.

## 4. Implement PTY Management

- Create a function to spawn a new PTY process using `forkpty`.
- This function will be called when a new, non-existent session is requested.
- Implement functions to read from and write to the PTY file descriptor.

## 5. Implement the Main Event Loop

- The core of the daemon will be an event loop (using `libxev` on Linux) that concurrently handles:
    1.  New client connections on the main Unix socket.
    2.  Incoming requests from connected clients.
    3.  Output from the PTY processes.
- This will allow the daemon to be single-threaded and highly concurrent.

## 6. Implement Protocol Handlers

- For each message type defined in `protocol.md`, create a handler function:
    - `handle_list_sessions_request`: Responds with a list of all active sessions.
    - `handle_attach_session_request`: Adds the client to the session's list of connected clients and sends them the scrollback buffer.
    - `handle_detach_session_request`: Removes the client from the session's list.
    - `handle_kill_session_request`: Terminates the PTY process and removes the session.
    - `handle_pty_input`: Writes the received data to the corresponding PTY.
- When there is output from a PTY, the daemon will create a `pty_output` message and send it to all attached clients.

## 7. Integrate with `main.zig`

- In `main.zig`, when the `daemon` subcommand is parsed, call the main entry point of the `daemon` module.
- Pass the parsed command-line options (e.g., `--socket-path`) to the daemon's initialization function.

## 8. Do **NOT** Handle Daemonization

This command will be run under a systemd unit file so it does not need to concern itself with daemonizing itself.
