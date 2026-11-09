---
title: Install & Usage
description: How to install and use zmx for terminal session persistence
keywords: [zmx, install, usage, cli, getting, started]
toc: 3
---

## install

### binaries

- https://zmx.sh/a/zmx-1.0.1-linux-aarch64.tar.gz
- https://zmx.sh/a/zmx-1.0.1-linux-x86_64.tar.gz
- https://zmx.sh/a/zmx-1.0.1-macos-aarch64.tar.gz
- https://zmx.sh/a/zmx-1.0.1-macos-x86_64.tar.gz

### homebrew

```bash
brew install neurosnap/tap/zmx
```

### gh releases

We upload our binaries to github as well: https://github.com/neurosnap/zmx/releases

### mise-en-place

```bash
mise use zmx
```

### NixOS / nixpkgs

Run immediately without installation:

```sh
nix run github:NixOS/nixpkgs/nixpkgs-unstable#zmx
# or build main yourself
nix run github:neurosnap/zmx
```

Start a shell with zmx available while it runs:

```sh
nix shell github:NixOS/nixpkgs/nixpkgs-unstable#zmx
# or build main yourself
nix run github:neurosnap/zmx
```

### packages (unofficial)

- [Alpine Linux](https://pkgs.alpinelinux.org/package/edge/community/x86_64/zmx)
- [Arch AUR tracking releases](https://aur.archlinux.org/packages/zmx)
- [Arch AUR tracking git](https://aur.archlinux.org/packages/zmx-git)
- [openSUSE Tumbleweed](https://software.opensuse.org/package/zmx)
- [Gentoo (overlay)](https://codeberg.org/samuelhautamaki/samuelhautamaki-gentoo)
- [zmx-rpm packaging](https://github.com/engie/zmx-rpm/)

### src

- Requires zig `v0.17`
- Clone the repo
- Run build cmd

Be sure to add `~/.local/bin` to your `PATH`:

```bash
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

## usage

> **Important:** We recommend closing the terminal window to detach from the session, but you can also press `ctrl+\` or run `zmx detach`. If you need `ctrl+\` for something else (e.g. vim's `ctrl+\ ctrl+n` to escape its own `:terminal`), set `ZMX_NO_DETACH_KEY` to disable the shortcut and rely on `zmx detach` or closing the window instead.

Run `zmx help` for more information on usage, with examples.

```
Usage: zmx <command> [args...]

Commands:
  [a]ttach <name> [command...]                             Attach to session, creating if needed
  [r]un <name> [-d] [command...]                           Send command without attaching
  [s]end <name> <text...>                                  Send raw input to session PTY
  [p]rint <name> <text...>                                 Inject text into session display
  [wr]ite <name> <file_path>                               Write stdin to file_path through the session
  [d]etach                                                 Detach all clients (ctrl+\\ for current client)
  [l]ist|ls [--short]                                      List active sessions
  [g]et <name>                                             Get session labels
  set <name> k=v ...                                       Set session labels
  [cl]ear <name>                                           Clear all session labels
  print-env [-s] <name> [key]                              Print tracked environment variables
  [k]ill <name>... [--force]                               Kill session and all attached clients
  [hi]story <name> [--vt|--html] [--screen|scrollback]     Output session scrollback
  [w]ait <name>...                                         Wait for session tasks to complete
  [t]ail <name>...                                         Follow session output
  [c]ompletions <shell>                                    Shell completions (bash, zsh, fish, nu, yash)
  [v]ersion                                                Show version and metadata (socket dir, log dir)
  [h]elp                                                   Show this help
```

## nested sessions

Nested sessions are not supported. Inside a session, `ZMX_SESSION` is set. Running `zmx attach <name>` inside an existing session switches the attached client to `<name>` instead of nesting.

Child processes inherit `ZMX_SESSION`, so a script or tool that runs `zmx attach other` from inside a session will switch your active terminal to `other`.

To attach from a subprocess without switching the caller's client, unset `ZMX_SESSION`:

```bash
env -u ZMX_SESSION zmx attach other
```

For non-interactive work prefer `zmx run`, which never switches the caller.

## session prefix

We allow users to set an environment variable `ZMX_SESSION_PREFIX` which will prefix the name of the session for all commands. This means if that variable is set, every command that accepts a session will be prefixed with it.

```bash
export ZMX_SESSION_PREFIX="d."
zmx a runner # ZMX_SESSION=d.runner
zmx a tests  # ZMX_SESSION=d.tests
zmx k tests  # kills d.tests
zmx wait     # suspends until all tasks prefixed with "d." are complete
```
