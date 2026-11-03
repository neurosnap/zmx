# Daemon capabilities

Capabilities add behavior to a zmx session through compiled Zig modules. They can
remember program reports, respond to requests from programs, and restore information
when a terminal reconnects. Their protocol rules and saved information stay outside
the core daemon loop.

This guide uses OSC 7501 Program Status as a running example. OSC 7 working
directory restoration provides a smaller example of the same interface.

- [OSC 7](https://ghostty.org/docs/vt/osc/7) reports the current working directory.
  Ghostty already remembers it, and zmx uses it for session listings and new shells.
  The capability reads that same record to restore the directory on reconnect.
- [OSC 7501 Program Status](https://www.superlogical.com/rex/docs/build/program-status)
  reports whether a program is working, waiting for input, or finished. Its
  capability remembers the latest report for each task, including nested tasks
  such as `build/test`. It also responds to programs asking whether reporting is supported
  while no terminal is connected.

For example, an agent might report that it is waiting for permission while no
terminal is connected. Forwarding new output alone would leave the next terminal
unaware of that status. The Program Status capability restores the saved report
on reconnect.

## Enable optional capabilities

`--capabilities=<names>` selects a comma-separated list of optional capability
names for `attach` or `run`. Place it before the session name. To include Program
Status, run

```sh
zmx attach --capabilities=osc7501 agent
```

Omitting the option or passing `--capabilities=` adds no optional capabilities.
Names select modules already compiled into the executable. There is no runtime
loading of `.zig` files.
Registered capabilities marked `always_active` are always included. OSC 7 uses
this setting to preserve existing working directory behavior without requiring
users or embedding applications to select it.

Always-active capabilities run first in registry order, followed by optional ones
in the requested order. This controls reconnect message order and gives earlier
capabilities priority when replying. Unknown names, empty entries within a list,
and repeated names are rejected. Do not add an always-active capability to the
optional list.

A daemon keeps its original selection and one instance of each capability until
the session ends. Later clients cannot change the selection. Saved information
survives terminal disconnects but is lost when the daemon ends. For `attach`,
a nonempty `--capabilities` selection must be made from outside a running zmx
session, because session switching passes only the target name.

Applications embedding libzmx use the `optional_capabilities` property inside
`CreateOptions`, `AttachOptions`, or `RunOptions`.
Only the supplied list selects optional capabilities. It defaults to empty and
never reads the environment. Always-active capabilities remain included. The
[definitions module](../src/capabilities/definitions.zig) has a short example.
Applications can also compile their own implementations and supply their definitions
through these options.

## How capabilities receive information

**Program output** contains text and terminal commands. zmx forwards the bytes to
attached terminals and gives them to Ghostty to maintain the saved screen.

```text
Program output
    +--> Attached terminals receive forwarded output
    |
    +--> Ghostty parses an action
              --> Each capability observes the same action
              --> Ghostty updates its saved terminal state
```

Ghostty already parses protocols including OSC 7501. The shared dispatcher forwards
its actions without interpreting their protocol tags. Each capability handles the
actions it recognizes. Capabilities can also receive OSC commands that Ghostty
does not recognize.

A **query** is a terminal command by which a program requests information, such as
whether Program Status is supported. A **reply** goes back through the program's
input. When a terminal is attached, zmx leaves replies to it. Otherwise, a capability
can reply. Every capability still receives the event so its information
stays complete, even if another capability replies.

On reconnect, zmx sends the saved screen and capability restore messages before
resuming any unfinished terminal command and live output. This order keeps the
terminal from interpreting restore messages as part of the unfinished command.

## Implement a capability

A capability is a Zig struct holding one session's data. It supplies four methods

| Method | Purpose |
| --- | --- |
| `init` | Create the data for this session. |
| `deinit` | Release that data. |
| `observe` | Update it as events arrive, optionally replying to a query. |
| `restore` | Replay saved information by writing terminal commands to the supplied writer. |

`zmx.capabilities.Definition.of("my-capability", MyCapability)` describes the
implementation for zmx. The [API documentation](../src/capabilities.zig) gives the
method signatures, ownership rules, failure handling, and parser limits.

Start with the [OSC 7 implementation](../src/capabilities/working_directory/main.zig)
for a capability that reuses Ghostty's data. The
[Program Status implementation](../src/capabilities/program_status/main.zig) shows
how to maintain separate task records and respond to queries.

The [registry](../src/capabilities/registry.zig) assembles required and optional
capabilities from the [definitions](../src/capabilities/definitions.zig) supplied
with zmx. To omit a capability from a build, remove its export and registry entry.
The [daemon integration](../src/loop.zig) connects the shared API to program input,
output, and client connections without handling each capability's protocol.

See [running tests](../test/README.md) for the test layout and commands.
