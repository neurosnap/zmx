# Changelog

Use spec: https://common-changelog.org/

## Unreleased

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
