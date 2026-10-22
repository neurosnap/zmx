# zmx package examples

Usage examples for the `zmx` Zig package (the programmatic interface in
`src/lib.zig`).

## Building

```sh
zig build examples
```

Installs the example binaries to `zig-out/bin/`.

## Examples

- **`example-run-and-wait`** — run a command in a task-mode session, stream
  its output, read the scrollback, and kill the session.
- **`example-list-sessions`** — list active sessions with pid, exit code, and
  labels.

## Using the package from another project

```zig
// build.zig.zon
.dependencies = .{
    .zmx = .{
        .url = "git+https://github.com/you/zmx#<commit>",
        .hash = "...",
    },
},
```

```zig
// build.zig
const zmx = b.dependency("zmx", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zmx", zmx.module("zmx"));
```

```zig
// your source
const zmx = @import("zmx");
const exit_code = try zmx.run(gpa, io, "my-session", &.{"echo", "hi"}, .{});
```

Notes:

- All functions take `(alloc, io, ...)` — get them from `std.process.Init`.
- `zmx.list()` returns a slice you must free, and each `SessionEntry` has
  allocated fields freed via `entry.deinit(alloc)` (see
  `list_sessions.zig`).
- `zmx.create()` is only available when the package is built with
  `-Ddaemon=true` (the default).
