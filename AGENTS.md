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

## finding libxev source code

To inspect the source code for libxev, look inside the `libxev_src` folder.

## finding zig std library source code

To inspect the source code for zig's standard library, look inside the `zig_std_src` folder.

## finding ghostty library source code

To inspect the source code for zig's standard library, look inside the `ghostty_src` folder.

### prior art - shpool

The project that most closely resembles `shpool`.

You can find the source code at this repo: https://github.com/shell-pool/shpool

`shpool` is a service that enables session persistence by allowing the creation of named shell sessions owned by `shpool` so that the session is not lost if the connection drops.

`shpool` can be thought of as a lighter weight alternative to tmux or GNU screen. While tmux and screen take over the whole terminal and provide window splitting and tiling features, `shpool` only provides persistent sessions.

The biggest advantage of this approach is that `shpool` does not break native scrollback or copy-paste.
