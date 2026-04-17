# Changelog

Use spec: https://common-changelog.org/

## Staged

## v0.5.0 - 2026-04-16

### Added

- New client leader policy: last client to send user input bytes (non-ansi escape codes) becomes the leader
  - The client leader controls resizing and any other terminal state changes
  - Non-leader clients are read-only until they send user input bytes and takeover leadership
  - When a leader is promoted we immediately resize to their window size
- `zmx attach` now lets users switch to another session from within a session
- `zmx tail` will receive all outout from sessions in read-only mode
- `zmx write` will pipe data from stdin, convert to base64, chunk, and send data through pty to write to a file

### Changed

- *BREAKING* `zmx run` is now synchonous by default and tails the session
  - Use detached mode (`-d`) for previous behavior
- *BREAKING* `kill` and `wait` now require "\*" suffix for wildcard match sessions
  - e.g. `zmx kill "d.*"`, `zmx kill "*"`, `zmx wait "test*"`
- `zmx run` accepts `--fish` flag to indicate the session's shell is fish
- `zmx kill` now supports multiple args and it will kill sessions that match a prefix
  - e.g. `zmx kill "d.*"` will kill all sessions that match that prefix

### Fixed

- `zmx list` will send "no sessions found" to stderr instead of stdout
- `zmx wait` will send errors to stderr instead of stdout
- Rewrite OSC `133;A` with `redraw=0` to prevent prompt loss on resize

## v0.4.2 - 2026-03-18

### Changed

- `zmx list` renamed keys and made formatting more stable
- More accurate fish completions

### Fixed

- Validate session name length against Unix socket path limit
- Use platform-correct `O_NONBLOCK` for fcntl
- Daemon ignore `SIGPIPE`, handle `EINTR` in poll
- Daemon isolate forked child from parent code path and heap-alloc argv
- `zmx run` stdin regression with `ZMX_TASK_COMPLETED`
- `zmx run` when no client is attached, send DA response query from daemon
- `zmx run` re-quote when using shell meta chars
- `zmx wait` use-after-free
- `zmx wait` time out after 3 polls if no matching sessions are found
- `zmx list` clean up socket on `ConnectionRefused`, not `Timeout`

## v0.4.1 - 2026-02-23

### Fixed

- Update `libghostty` to fix `zig build test`

## v0.4.0 - 2026-02-20

### Added

- New environment variable `ZMX_SESSION_PREFIX` which will be inserted before every session name for every command
- New command `zmx wait` which will stall until all tasks (`zmx run`) are completed.

### Changed

- `zmx version` now returns the socket and log directory locations
- `zmx run` now inserts a `ZMX_TASK_COMPLETED` marker after every run command to indicate when the task is completed and then returns the aggregate exit status

### Fixed

- `libghostty` had a regression that caused `zmx` to crash

## v0.3.0 - 2026-02-01

### Added

- New flag `--vt` for `zmx [hi]story` which prints raw ansi escape codes for terminal session
- New flag `--html` for `zmx [hi]story` which prints html representation of terminal session
- New list flag `zmx [l]ist [--list]` that lists all session names with no extra information
- New command `zmx [c]ompletions <shell>` that outputs auto-completion scripts for a given shell
- List command `zmx list` now shows `started_at` showing working directory when creating session
- List command `zmx list` now shows `cmd` showing command provided when creating session
- List command `zmx list` now shows `→` arrow indicating the current session

### Fixed

- On restore, background colors for whitespace now properly filled
- Spawn login shell instead of normal shell
- Properly cleanup processes (parent and children) during `zmx kill` or SIGTERM

## v0.2.0 - 2025-12-29

### Added

- New command `zmx [hi]story <name>` which prints the session scrollback as plain text
- New command `zmx [r]un <name> <cmd>...` which sends a command without attaching, creating session if needed
- Use `XDG_RUNTIME_DIR` environment variable for socket directory (takes precedence over `TMPDIR` and `/tmp`)

### Changed

- Updated `ghostty-vt` to latest HEAD

### Fixed

- Restore mouse terminal modes on detach
- Restore correct cursor position on re-attach

## v0.1.1 - 2025-12-16

### Changed

- `zmx list`: sort by session name

### Fixed

- Send SIGWINCH to PTY on re-attach
- Use default terminal size if cols and rows are 0

## v0.1.0 - 2025-12-09

### Changed

- **Breaking:** unix socket and log files have been moved from `/tmp/zmx` to `/tmp/zmx-{uid}` with folder/file perms set to user

If you upgraded and need to kill your previous sessions, run `ZMX_DIR=/tmp/zmx zmx kill {sesion}` for each session.

### Added

- Use `TMPDIR` environment variable instead of `/tmp`
- Use `ZMX_DIR` environment variable instead of `/tmp/zmx-{uid}`
- `zmx version` prints the current version of `zmx` and `ghostty-vt`
