# ZMX Client-Daemon Communication Protocol

This document specifies the communication protocol between `zmx` clients and the `zmx daemon` over a Unix socket.

## Transport

The communication occurs over a Unix domain socket. The path to the socket is configurable via the `--socket-path` option of the `daemon` subcommand.

## Serialization

All messages are currently serialized using **newline-delimited JSON (NDJSON)**. Each message is a JSON object terminated by a newline character (`\n`). This allows for simple streaming and parsing of messages while maintaining human-readable logs for debugging.

### Implementation

The protocol implementation is centralized in `src/protocol.zig`, which provides:
- Typed message structs for all payloads
- `MessageType` enum for type-safe dispatching
- Helper functions: `writeJson()`, `parseMessage()`, `parseMessageType()`
- `LineBuffer` for efficient NDJSON line buffering

### Binary Frame Support

The protocol uses a hybrid approach: JSON for control messages and binary frames for PTY output to avoid encoding overhead and improve throughput.

**Frame Format:**
```
[4-byte length (little-endian)][2-byte type (little-endian)][payload...]
```

**Frame Types:**
- Type 1 (`json_control`): JSON control messages (not currently used in framing)
- Type 2 (`pty_binary`): Raw PTY output bytes

**Current Usage:**
- Control messages (attach, detach, kill, etc.): NDJSON format
- PTY output from daemon to client: Binary frames (type 2)
- PTY input from client to daemon: JSON `pty_in` messages (may be optimized to binary frames in future)

## Message Structure

Each message is a JSON object with two top-level properties:

- `type`: A string that identifies the type of the message (e.g., `list_sessions_request`).
- `payload`: A JSON object containing the message-specific data.

### Requests

Requests are sent from the client to the daemon.

### Responses

Responses are sent from the daemon to the client in response to a request. Every response will have a `status` field in its payload, which can be either `ok` or `error`. If the status is `error`, the payload will also contain an `error_message` field.

## Message Types

### `list_sessions`

- **Direction**: Client -> Daemon
- **Request Type**: `list_sessions_request`
- **Request Payload**: (empty)

- **Direction**: Daemon -> Client
- **Response Type**: `list_sessions_response`
- **Response Payload**:
    - `status`: `ok`
    - `sessions`: An array of session objects.

**Session Object:**

- `name`: string
- `status`: string (`attached` or `detached`)
- `clients`: number
- `created_at`: string (ISO 8601 format)

### `attach_session`

- **Direction**: Client -> Daemon
- **Request Type**: `attach_session_request`
- **Request Payload**:
    - `session_name`: string
    - `rows`: u16 (terminal height in rows)
    - `cols`: u16 (terminal width in columns)

- **Direction**: Daemon -> Client
- **Response Type**: `attach_session_response`
- **Response Payload**:
    - `status`: `ok` or `error`
    - `error_message`: string (if status is `error`)

### `detach_session`

- **Direction**: Client -> Daemon
- **Request Type**: `detach_session_request`
- **Request Payload**:
    - `session_name`: string

- **Direction**: Daemon -> Client
- **Response Type**: `detach_session_response`
- **Response Payload**:
    - `status`: `ok` or `error`
    - `error_message`: string (if status is `error`)

### `kill_session`

- **Direction**: Client -> Daemon
- **Request Type**: `kill_session_request`
- **Request Payload**:
    - `session_name`: string

- **Direction**: Daemon -> Client
- **Response Type**: `kill_session_response`
- **Response Payload**:
    - `status`: `ok` or `error`
    - `error_message`: string (if status is `error`)

### `pty_in`

- **Direction**: Client -> Daemon
- **Message Type**: `pty_in`
- **Format**: NDJSON
- **Payload**:
    - `text`: string (raw UTF-8 text from terminal input)

This message is sent when a client wants to send user input to the PTY. It is a fire-and-forget message with no direct response. The input is forwarded to the shell running in the session's PTY.

### `pty_out`

- **Direction**: Daemon -> Client
- **Message Type**: `pty_out`
- **Format**: NDJSON (used only for control sequences like screen clear)
- **Payload**:
    - `text`: string (escape sequences or control output)

This JSON message is sent for special control output like initial screen clearing. Regular PTY output uses binary frames (see below).

### PTY Binary Output

- **Direction**: Daemon -> Client
- **Format**: Binary frame (type 2: `pty_binary`)
- **Payload**: Raw bytes from PTY output

The majority of PTY output is sent using binary frames to avoid JSON encoding overhead. The frame consists of a 6-byte header (4-byte length + 2-byte type) followed by raw PTY bytes. This allows efficient streaming of terminal output without escaping or encoding.
