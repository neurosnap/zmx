# zmx session restore specification

This document outlines the specification how we are going to preserve session state so when a client reattaches to a session using `zmx reattach {session}` it will restore the session to its last state.

## purpose

The `zmx attach` subcommand starts re-attaches to a previously created session. When doing this we want to restore the session to its current state, displaying the last working screen text, layout, text wrapping, etc. This will include a configurable scrollback buffer size that will also be restored upon reattach.

## technical details

- The daemon spawns the shell on a pty master.
- Every byte the shell emits is parsed on-the-fly by the in-process terminal emulator (libghostty-vt).
- The emulator updates an internal 2-D cell grid (the “snapshot”) and forwards the same raw bytes to no-one while no client is attached.
- When a client is attached, the daemon also proxies those bytes straight to the client’s socket; the emulator runs in parallel only to keep the snapshot current.
- When you reattach, the daemon does not send the historic byte stream; instead it renders the current grid into a fresh ANSI sequence and ships that down the Unix-domain socket to the new shpool attach client.
- The client simply write()s that sequence to stdout—your local terminal sees it and redraws the screen instantly.

So the emulator is not “between” client and daemon in the latency sense; it is alongside, maintaining state. The only time it interposes is on re-attach: it briefly synthesizes a single frame so your local terminal can show the exact session image without having to replay minutes or hours of output.

## using libghostty-vt

- Feature superset: SIMD parsing, full Unicode grapheme clusters, Kitty graphics, sixel, and thousands of CSI/DEC/OSC commands already implemented and fuzz-tested
- Memory model: it hands you a read-only snapshot of the grid that you can memcpy straight into your re-attach logic—no allocator churn.
- No I/O policy: it is stateless by design; you feed it bytes when they arrive from the pty and later ask for the current screen.
