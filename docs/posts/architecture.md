---
title: Architecture & Philosophy
description: Design philosophy, implementation details, prior art, and feature comparison
keywords: [zmx, architecture, philosophy, libghostty-vt, tmux, shpool, abduco]
toc: 3
---

## philosophy

The entire argument for `zmx` instead of something like `tmux` that has windows, panes, splits, etc. is that job should be handled by your os window manager. By using something like `tmux` you now have redundant functionality in your dev stack: a window manager for your os and a window manager for your terminal. Further, in order to use modern terminal features, your terminal emulator **and** `tmux` need to have support for them. This holds back the terminal enthusiast community and feature development.

Instead, this tool specifically focuses on session persistence and defers window management to your os wm.

## a smol contract

- Write programs that solve a well defined problem.
- Write programs that behave the way most users expect them to behave.
- Write programs that a single person can maintain.
- Write programs that compose with other smol tools.
- Write programs that can be finished.

## impl

- The `daemon` and client processes communicate via a unix socket
- Both `daemon` and `client` loops leverage `poll(2)`
- Each session creates its own unix socket file
- We restore terminal state and output using `libghostty-vt`

### libghostty-vt

We use `libghostty-vt` to restore the previous state of the terminal when a client re-attaches to a session.

How it works:

- user creates session `zmx attach term`
- user interacts with terminal stdin
- stdin gets sent to pty via daemon
- daemon sends pty output to client *and* `ghostty-vt`
- `ghostty-vt` holds terminal state and scrollback
- user disconnects
- user re-attaches to session
- `ghostty-vt` sends terminal snapshot to client stdout

In this way, `ghostty-vt` doesn't sit in the middle of an active terminal session, it simply receives all the same data the client receives so it can re-hydrate clients that connect to the session. This enables users to pick up where they left off as if they didn't disconnect from the terminal session at all. It also has the added benefit of being very fast, the only thing sitting in-between you and your PTY is a unix socket.

## prior art

Below is a list of projects that inspired me to build this project. Architecturally, `zmx` uses aspects of both projects. For example, `shpool` inspired the idea of having libghostty restore the terminal state on reattach. Abduco inspired the idea of one daemon (and unix socket) per session.

### shpool

https://github.com/shell-pool/shpool

`shpool` is a service that enables session persistence by allowing the creation of named shell sessions owned by `shpool` so that the session is not lost if the connection drops.

### abduco

https://github.com/martanne/abduco

abduco provides session management (i.e. it allows programs to be run independently from its controlling terminal). Together with dvtm it provides a simpler alternative to tmux or screen.

## comparison

| Feature                        | zmx | shpool | abduco | dtach | tmux |
| ------------------------------ | --- | ------ | ------ | ----- | ---- |
| 1:1 Terminal emulator features | ✓   | ✓      | ✓      | ✓     | ✗    |
| Terminal state restore         | ✓   | ✓      | ✗      | ✗     | ✓    |
| Window management              | ✗   | ✗      | ✗      | ✗     | ✓    |
| Multiple clients per session   | ✓   | ✗      | ✓      | ✓     | ✓    |
| Native scrollback              | ✓   | ✓      | ✓      | ✓     | ✗    |
| Configurable detach key        | ✗   | ✓      | ✓      | ✓     | ✓    |
| Auto-daemonize                 | ✓   | ✓      | ✓      | ✓     | ✓    |
| Daemon per session             | ✓   | ✗      | ✓      | ✓     | ✗    |
| Session listing                | ✓   | ✓      | ✓      | ✗     | ✓    |
