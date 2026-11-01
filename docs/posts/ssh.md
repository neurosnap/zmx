---
title: SSH workflow
description: Using zmx with SSH multiplexing and autossh for remote sessions
keywords: [zmx, ssh, autossh, remote, controlmaster]
toc: 3
---

## try it out quickly

If you'd like to try out `zmx` and `ssh` without fiddling your `ssh` config, make sure to pass the `-t` option to `ssh`. Here's an example:

```bash
ssh -t dev-box zmx attach default
```

Without `-t`, the remote shell will not know it's talking to a terminal, and the display will likely get messed up.

This option isn't needed if you follow the configuration steps below, because `RequestTTY yes` does the same thing.

## configure it for regular use

Using `zmx` with `ssh` is a first-class citizen. Instead of using `ssh` to remote into your system with a single terminal and `n` tmux panes, you open `n` terminals and run `ssh` for all of them. This might sound tedious, but there are tools to make this a delightful workflow.

First, create an `ssh` config entry for your remote dev server:

```bash
Host = d.*
    HostName 192.168.1.xxx

    RemoteCommand zmx attach %k
    RequestTTY yes
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlMaster auto
    ControlPersist 10m
```

Architecturally, `ssh` supports multiplexing multiple channels of communication within a single connection to a server. `ControlMaster` is the setting that tells `ssh` to multiplex multiple PTY sessions to a single server over one tcp connection. Neat!

Now you can spawn as many terminal sessions as you'd like:

```bash
ssh d.term
ssh d.irc
ssh d.pico
ssh d.dotfiles
```

Because the `attach` command is essentially an "upsert", this will create or attach to each session.

Now you can use the [`autossh`](https://linux.die.net/man/1/autossh) tool to make your ssh connections auto-reconnect. For example, if you have a laptop and close/open your lid it will automatically reconnect all your ssh connections:

```bash
autossh -M 0 -q d.term
```

Or create an `alias`/`abbr`:

```fish
abbr -a ash "autossh -M 0 -q"
```

```bash
ash d.term
ash d.irc
ash d.pico
ash d.dotfiles
```

Wow! Now you can setup all your os tiling windows how you like them for your project and have as many windows as you'd like, almost replicating exactly what `tmux` does but with native windows, tabs, splits, and scrollback! It also has the added benefit of supporting all the terminal features your emulator supports, no longer restricted by what `tmux` supports.

The end-game here would be to leverage your window manager's ability to automatically arrange your windows for each project with a single command.
