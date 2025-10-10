# zmx - session persistence for terminal processes

## features

- Persist terminal shell sessions (pty processes)
- Ability to attach and detach from a shell session without killing it
- Native terminal scrollback
- Manage shell sessions
- Multiple clients can connect to the same session
- Background process (`daemon`) manages all pty processes
- A cli tool to interact with `daemon` and all pty processes
- Re-attaching to a session restores previous terminal state and output
- The `daemon` and client processes communicate via a unix socket
- The `daemon` is managed by a supervisor like `systemd`
- We provide a `systemd` unit file that users can install that manages the `daemon` process
- The cli tool supports the following commands:
    - `attach {session}`: attach to the pty process
    - `detach`: detach from the pty process without killing it
    - `kill {session}`: kill the pty process
    - `list`: show all sessions and what clients are currently attached
    - `daemon`: the background process that manages all sessions
- This project does **NOT** provide windows, tabs, or window splits
- It supports all the terminal features that the client's terminal emulator supports
- The current version only works on linux

## usage

- `zmx daemon` - start the background process that all other commands communicate with
- `zmx attach <session_name>` - create or attach to a session
- `zmx detach` (or Ctrl+b + d) - detach from session while keeping pty alive
- `zmx list` - list sessions
- `zmx kill <session_name>` kill pty and all clients attached to session
