# Daemon capabilities

Capabilities add behavior to a zmx session through compiled Zig modules. They can
remember program output, answer queries while detached, and restore information
when a terminal reconnects. Their rules and saved information stay outside the
daemon loop.

## Configuration

The built-in registry starts empty. Applications embedding libzmx supply their
own definitions through `optional_capabilities` in `CreateOptions`, `AttachOptions`,
or `RunOptions`. The list defaults to empty.

The registry maps `--capabilities=<names>` to compiled definitions for `attach`
and `run`. Place the comma-separated list before the session name. Unknown or
repeated names are rejected. Registered definitions marked `always_active` run
first, followed by optional definitions in the requested order.

A daemon keeps its selection and one instance per definition until the session
ends. Disconnecting a terminal does not destroy that data. Existing OSC 7 working
directory restoration remains in the terminal serializer.

## Implement a capability

A capability is a Zig struct holding one session's data with four methods:

| Method | Purpose |
| --- | --- |
| `init` | Create the data for this session. |
| `deinit` | Release that data. |
| `observe` | Update it as events arrive, optionally replying to a query. |
| `restore` | Write complete terminal commands that replay saved information. |

`zmx.capabilities.Definition.of("my-capability", MyCapability)` describes the
implementation. The [API documentation](../src/capabilities.zig) gives the method
signatures, ownership rules, failure handling, and parser limits.

One parser delivers actions to capabilities and updates Ghostty's terminal state.
Every capability receives each event. When detached, the first capability to
answer a query owns the reply. An attached terminal owns replies instead.

Reconnect sends the saved screen, capability restore messages, and any unfinished
terminal command in that order. A failed restore discards that capability's
messages and leaves the remaining restores available.

The [registry](../src/capabilities/registry.zig) selects definitions. The
[daemon](../src/loop.zig) connects their callbacks to program input and terminal
connections without interpreting each capability's protocol.

See [running tests](../test/README.md) for validation commands.
