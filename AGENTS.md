# zmx

The goal of this project is to create a way to attach and detach terminal sessions without killing the underlying linux process.

## tech stack

- `zig` v0.15.1
- `libghostty-vt` for terminal escape codes and terminal state management
- `libxev` for handling single-threaded, non-blocking, async flow control
- `clap` for building the cli
- `systemd` for background process supervision

## commands

- **Build:** `zig build`
- **Build Check (Zig)**: `zig build check`
- **Test (Zig):** `zig build test`
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`

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
    - `detach {session}`: detach from the pty process without killing it
    - `kill {session}`: kill the pty process
    - `list`: show all sessions and what clients are currently attached
    - `daemon`: the background process that manages all sessions
- This project does **NOT** provide windows, tabs, or window splits
- It supports all the terminal features that the client's terminal emulator supports
- The current version only works on linux

## finding libxev source code

To inspect the source code for libxev, look inside the `libxev_src` folder.

## finding zig std library source code

To inspect the source code for zig's standard library, look inside the `zig_std_src` folder.

### prior art - shpool

The project that most closely resembles `shpool`.

You can find the source code at this repo: https://github.com/shell-pool/shpool

`shpool` is a service that enables session persistence by allowing the creation of named shell sessions owned by `shpool` so that the session is not lost if the connection drops.

`shpool` can be thought of as a lighter weight alternative to tmux or GNU screen. While tmux and screen take over the whole terminal and provide window splitting and tiling features, `shpool` only provides persistent sessions.

The biggest advantage of this approach is that `shpool` does not break native scrollback or copy-paste.
