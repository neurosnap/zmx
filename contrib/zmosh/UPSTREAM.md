# Source provenance

This contribution adapts the remote CLI and gateway from
[mmonad/zmosh](https://github.com/mmonad/zmosh) at commit
`71eba23416bfb443df755ad89d6d06e665ebcd95` (2026-02-22).
The original license is preserved in [LICENSE](LICENSE).

`crypto.zig`, `udp.zig`, `transport.zig`, `remote.zig`, and `serve.zig`
derive from that revision. The CLI/bootstrap and protocol adapter replace the
fork's integration into its own copy of zmx. The C library and Apple framework
targets are not included.

The port uses current zmx session, configuration, socket and terminal code
through the `libzmx` module (`src/lib.zig`). It does not vendor a second daemon or Ghostty
revision.


Notable adaptations:

- Zig 0.16 I/O, secure entropy, platform calls and monotonic clocks.
- Explicit conversion between remote messages and current local IPC. In
  particular, remote `SessionEnd=11` is not local `Switch=11`.
- Ordered receive buffers and an anchored 32-packet transmission window.
  Output, including terminal restoration, uses reliable records. This favors
  correctness over responsiveness during sustained packet loss.
- Exact key-length checks, replay rejection from the first packet, nonce
  reservation before send, and sequence-exhaustion failures.
- Quoted SSH bootstrap, finite process supervision, and a detached gateway.
- A provisional native Init/Detach followed by reconnect restores output emitted
  before the core's first attachment, without changing core startup behavior.
  The provisional snapshot is discarded; only the second attachment is visible.
- Bounded queues, progress deadlines, and explicit incomplete-output errors.

The XChaCha20-Poly1305 construction and encrypted datagram/transport framing
come from upstream. Delivery semantics have changed: install matching versions
of this contribution on both machines. Interoperability with the original fork
is not promised. Tests are not a cryptographic security audit.

The integration also includes a focused core terminal-serialization fix: preserve
the last viewport-height rows of restored scrollback before clearing the visible
screen. A native roundtrip regression reproduces the loss independently of UDP.
