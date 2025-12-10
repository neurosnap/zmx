# Changelog

## v0.1.0 - 2025-12-09

### Changed

- **Breaking:** unix socket and log files have been moved from `/tmp/zmx` to `/tmp/zmx-{uid}` with folder/file perms set to user

If you upgraded and need to kill your previous sessions, run `ZMX_DIR=/tmp/zmx zmx kill {sesion}` for each session.

### Added

- Use `TMPDIR` environment variable instead of `/tmp`
- Use `ZMX_DIR` environment variable instead of `/tmp/zmx-{uid}`
- `zmx version` prints the current version of `zmx` and `ghostty-vt`
