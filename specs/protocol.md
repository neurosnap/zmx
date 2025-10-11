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

### Future: Binary Frame Support

The protocol module includes infrastructure for future binary framing to optimize PTY data throughput:
- Frame format: `[4-byte length][2-byte type][payload...]`
- Type 1: JSON control messages (current)
- Type 2: Binary PTY data (future optimization)

This hybrid approach would keep control messages in human-readable JSON while allowing raw binary PTY data when profiling shows JSON is a bottleneck.

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

### `pty_input`

- **Direction**: Client -> Daemon
- **Request Type**: `pty_input`
- **Request Payload**:
    - `session_name`: string
    - `data`: string (base64 encoded)

This message does not have a direct response. It is a fire-and-forget message from the client.

### `pty_output`

- **Direction**: Daemon -> Client
- **Request Type**: `pty_output`
- **Request Payload**:
    - `session_name`: string
    - `data`: string (base64 encoded)

This message is sent from the daemon to an attached client whenever there is output from the PTY.
