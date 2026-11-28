# Daemon capabilities

Capabilities keep terminal protocol bookkeeping out of `loop.zig`, which handles
client and daemon communication. Every daemon runs the handlers listed in
`States` in `src/capabilities.zig`.

One parser delivers output actions to the handlers before updating Ghostty.
Accepted shell notifications arrive after Ghostty applies them. Handlers keep
session data across disconnects and can answer queries while no terminal is attached.

On reconnect, zmx sends the saved screen, each handler's restore messages, and
any unfinished terminal command, in that order. Each snapshot is queued whole
or skipped on failure, so a failed handler cannot send a partial snapshot or
prevent other handlers from restoring.
