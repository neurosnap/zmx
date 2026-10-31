---
title: Zig package
description: Use zmx as a library in Zig projects
keywords: [zmx, zig, package, library, api]
toc: 3
---

## using zmx as a zig package

The library in `src/lib.zig` is importable as the `zmx` package from other Zig projects. All functions take `(alloc, io, ...)` from `std.process.Init`.

```zig
// build.zig.zon
.dependencies = .{
    .zmx = .{
        .url = "git+https://github.com/neurosnap/zmx#<commit>",
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
const sessions = try zmx.list(gpa, io);
defer {
    for (sessions) |s| s.deinit(gpa);
    gpa.free(sessions);
}
```

## notes

- `zmx.run` creates the session (and daemon) if it doesn't exist, no need to call `zmx.create` first.
- `zmx.create` is only available when the package is built with `-Ddaemon=true` (the default).
- See [`examples/`](https://github.com/neurosnap/zmx/tree/main/examples) for complete working programs.
