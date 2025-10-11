# zmx

The goal of this project is to create a way to attach and detach terminal sessions without killing the underlying linux process.

When researching `zmx`, also read the README.md in the root of this project directory to learn more about the features, documentation, prior art, etc.

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

## find any library API definitions

Before trying anything else, run the `zigdoc` command to find an API with documentation:

```
zigdoc {symbol}
# examples
zigdoc ghostty-vt
zigdoc clap
zigdoc xev
zigdoc std.ArrayList
zigdoc std.mem.Allocator
zigdoc std.http.Server
```

Only if that doesn't work should you grep the project dir.

## find libxev source code

To inspect the source code for libxev, look inside the `libxev_src` folder.

## find zig std library source code

To inspect the source code for zig's standard library, look inside the `zig_std_src` folder.

## find ghostty library source code

To inspect the source code for zig's standard library, look inside the `ghostty_src` folder.
