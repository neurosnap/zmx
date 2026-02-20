# Changelog

Use spec: https://common-changelog.org/

## Staged

### Added

- New environment variable `ZMX_SESSION_PREFIX` which will be inserted before every session name for every command
- New command `zmx wait` which will stale until all tasks (`zmx run`) are completed.

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
