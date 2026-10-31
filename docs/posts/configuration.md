---
title: Configuration & Debugging
description: Socket directories, permissions, logs, and known issues
keywords: [zmx, configuration, socket, permissions, debugging, logs]
toc: 3
---

## socket file location

Each session gets its own unix socket file. The default location depends on your environment variables (checked in priority order):

1. `ZMX_DIR` => uses exact path (e.g., `/custom/path`)
1. `XDG_RUNTIME_DIR` => uses `{XDG_RUNTIME_DIR}/zmx` (recommended on Linux, typically results in `/run/user/{uid}/zmx`)
1. `TMPDIR` => uses `{TMPDIR}/zmx-{uid}` (appends uid for multi-user safety)
1. `/tmp` => uses `/tmp/zmx-{uid}` (default fallback, appends uid for multi-user safety)

## permissions

You can configure the permissions for the socket directory and log files using the following environment variables:

- `ZMX_DIR_MODE` => sets the mode for the socket and log directories (octal, defaults to `0750`)
- `ZMX_LOG_MODE` => sets the mode for the log files (octal, defaults to `0640`)

This is particularly useful when running `zmx` as a system service with a shared group. For example, setting `ZMX_DIR_MODE=0770` and `ZMX_LOG_MODE=0660` allows group members to attach to the session.

## debugging

We store global logs for cli commands in `{log_dir}/zmx.log`. We store session-specific logs in `{log_dir}/{session_name}.log`. Right now they are enabled by default and cannot be disabled. The idea here is to help with initial development until we reach a stable state.

The log directory is resolved in this order:

1. `ZMX_DIR/logs` if `ZMX_DIR` is set
1. `XDG_STATE_HOME/zmx/logs` if `XDG_STATE_HOME` is set
1. `HOME/.local/state/zmx/logs`
1. `TMPDIR/zmx-$UID` (or `/tmp/zmx-$UID`) as a last resort

## known issues

- When upgrading versions of `zmx` where we make changes to the underlying IPC communication, it will kill all your sessions because it cannot communicate through the daemon socket properly
- Terminal state restoration with nested `zmx` sessions through SSH: host A `zmx` -> SSH -> host B `zmx`
  - Specifically cursor position gets corrupted
  - Essentially this is unspecified and unsupported behavior
- When re-attaching and kitty keyboard mode was previously enabled, we try to re-send that CSI query to re-enable it
  - Some programs don't know how to handle that CSI query (e.g. `psql`) so when you type it echos kitty escape sequences erroneously
