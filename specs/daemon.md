# zmx daemon specification

This document outlines the specification for the `zmx daemon` subcommand, which runs the background process responsible for managing terminal sessions.

## purpose

The `zmx daemon` subcommand starts the long-running background process that manages all pseudo-terminal (PTY) processes. It acts as the central hub for session persistence, allowing clients to attach to and detach from active terminal sessions without terminating the underlying processes.

## responsibilities

The daemon is responsible for:

1.  **PTY Management**: Creating, managing, and destroying PTY processes using `fork` or `forkpty`.
2.  **Session State Management**: Maintaining the terminal state and a buffer of text output for each active session. This ensures that when a client re-attaches, they see the previous output and the correct terminal state.
3.  **Client Communication**: Facilitating communication between multiple `zmx` client instances and the managed PTY processes via a Unix socket.
4.  **Session Lifecycle**: Handling the lifecycle of sessions, including creation, listing, attachment, detachment, and termination (killing).
5.  **Resource Management**: Managing system resources associated with each session.

## usage

```
zmx daemon [options]
```

## options

- `-s`, `--socket-path <path>`: Specifies the path to the Unix socket for client-daemon communication. Defaults to a system-dependent location (e.g., `/tmp/zmx.sock`).
- `-b`, `--buffer-size <size>`: Sets the maximum size (in lines or bytes) for the session's scrollback buffer. Defaults to a reasonable value (e.g., 1000 lines).
- `-l`, `--log-level <level>`: Sets the logging level for the daemon (e.g., `debug`, `info`, `warn`, `error`). Defaults to `info`.

## systemd integration

The `zmx daemon` process is designed to be managed by `systemd`. A `systemd` unit file will be provided to ensure the daemon starts automatically on boot, restarts on failure, and logs its output appropriately.

## communication protocol

(To be defined in a separate `PROTOCOL.md` spec)

The daemon will expose an API over the Unix socket to allow clients to:

- List active sessions.
- Request attachment to a session.
- Send input to a session.
- Receive output from a session.
- Detach from a session.
- Kill a session.
