<img src="./logo.png" width="50px" height="50px">

# zmx

session persistence for terminal processes

Reason for this tool: [You might not need `tmux`](https://bower.sh/you-might-not-need-tmux)

## features

- Persist terminal shell sessions (pty processes)
- Ability to attach and detach from a shell session without killing it
- Native terminal scrollback
- Multiple clients can connect to the same session
- Re-attaching to a session restores previous terminal state and output
- Works on mac and linux
- This project does **NOT** provide windows, tabs, or splits

## install

### binaries

- https://zmx.sh/a/zmx-0.1.1-linux-aarch64.tar.gz
- https://zmx.sh/a/zmx-0.1.1-linux-x86_64.tar.gz
- https://zmx.sh/a/zmx-0.1.1-macos-aarch64.tar.gz
- https://zmx.sh/a/zmx-0.1.1-macos-x86_64.tar.gz

### homebrew

```bash
brew tap neurosnap/tap
brew install zmx
```

### src

- Requires zig `v0.15`
- Clone the repo
- Run build cmd

```bash
zig build -Doptimize=ReleaseSafe --prefix ~/.local
# be sure to add ~/.local/bin to your PATH
```

## usage

> [!IMPORTANT]
> Press `ctrl+\` to detach from the session.

```
Usage: zmx <command> [args]

Commands:
  [a]ttach <name> [command...]  Create or attach to a session
  [d]etach                      Detach all clients from current session  (ctrl+\ for current client)
  [l]ist                        List active sessions
  [k]ill <name>                 Kill a session and all attached clients
  [v]ersion                     Show version information
  [h]elp                        Show this help message
```

### examples

```bash
zmx attach dev              # start a shell session
zmx attach dev nvim .       # start nvim in a persistent session
zmx attach build make -j8   # run a build, reattach to check progress
zmx attach mux dvtm         # run a multiplexer inside zmx
```

## shell prompt

When you attach to a zmx session, we don't provide any indication that you are inside `zmx`. We do provide an environment variable `ZMX_SESSION` which contains the session name.

We recommend checking for that env var inside your prompt and displaying some indication there.

### fish

Place this file in `~/.config/fish/config.fish`:

```fish
functions -c fish_prompt _original_fish_prompt 2>/dev/null

function fish_prompt --description 'Write out the prompt'
  if set -q ZMX_SESSION
    echo -n "[$ZMX_SESSION] "
  end
  _original_fish_prompt
end
```

### bash

todo.

### zsh

Place this in `.zshrc`, update current `$PROMPT/$PS1` to `BASE_PROMPT`

```zsh
BASE_PROMPT=$PS1/$PROMPT
PROMPT="${ZMX_SESSION:+[$ZMX_SESSION]} $BASE_PROMPT"
```

## philosophy

The entire argument for `zmx` instead of something like `tmux` that has windows, panes, splits, etc. is that job should be handled by your os window manager. By using something like `tmux` you now have redundent functionality in your dev stack: a window manager for your os and a window manager for your terminal. Further, in order to use modern terminal features, your terminal emulator **and** `tmux` need to have support for them. This holds back the terminal enthusiast community and feature development.

Instead, this tool specifically focuses on session persistence and defers window management to your os wm.

## ssh workflow

Using `zmx` with `ssh` is a first-class citizen. Instead of `ssh`ing into your remote system with a single terminal and `n` tmux panes, you open `n` terminals and run `ssh` for all of them. This might sound tedious, but there are tools to make this a delightful workflow.

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

Now you can spawn as many terminal sessions as you'd like:

```bash
ssh d.term
ssh d.irc
ssh d.pico
ssh d.dotfiles
```

This will create or attach to each session and since we are using `ControlMaster` the same `ssh` connection is reused for every call to `ssh` for near-instant connection times.

Now you can use the [`autossh`](https://linux.die.net/man/1/autossh) tool to make your ssh connections auto-reconnect. For example, if you have a laptop and close/open your laptop lid it will automatically reconnect all your ssh connections:

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
ash d.dotifles
```

Wow! Now you can setup all your os tiling windows how you like them for your project and have as many windows as you'd like, almost replicating exactly what `tmux` does but with native windows, tabs, splits, and scrollback! It also has the added benefit of supporting all the terminal features your emulator supports, no longer restricted by what `tmux` supports.

## socket file location

Each session gets its own unix socket file. Right now, the default location is `/tmp/zmx-{uid}`. You can configure this using environment variables:

- `TMPDIR` => overrides `/tmp`
- `ZMX_DIR` => overrides `/tmp/zmx-{uid}`

## debugging

We store global logs for cli commands in `/tmp/zmx-{uid}/logs/zmx.log`. We store session-specific logs in `/tmp/zmx-{uid}/logs/{session_name}.log`. These logs rotate to `.old` after 5MB.

## a note on configuration

We are evaluating what should be configurable and what should not. Every configuration option is a burden for us maintainers. For example, being able to change the default detach shortcut is difficult in a terminal environment.

## a smol contract

- Write programs that solve a well defined problem.
- Write programs that behave the way most users expect them to behave.
- Write programs that a single person can maintain.
- Write programs that compose with other smol tools.
- Write programs that can be finished.

## impl

- The `daemon` and client processes communicate via a unix socket
- Both `daemon` and `client` loops leverage `poll()`
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

Below is a list of projects that inspired me to build this project.

### shpool

You can find the source code at this repo: https://github.com/shell-pool/shpool

`shpool` is a service that enables session persistence by allowing the creation of named shell sessions owned by `shpool` so that the session is not lost if the connection drops.

`shpool` can be thought of as a lighter weight alternative to tmux or GNU screen. While tmux and screen take over the whole terminal and provide window splitting and tiling features, `shpool` only provides persistent sessions.

The biggest advantage of this approach is that `shpool` does not break native scrollback or copy-paste.

### abduco

You can find the source code at this repo: https://github.com/martanne/abduco

abduco provides session management i.e. it allows programs to be run independently from its controlling terminal. That is programs can be detached - run in the background - and then later reattached. Together with dvtm it provides a simpler and cleaner alternative to tmux or screen.

### dtach

You can find the source code at this repo: https://github.com/crigler/dtach

A simple program that emulates the detach feature of screen.

dtach is a program written in C that emulates the detach feature of screen, which allows a program to be executed in an environment that is protected from the controlling terminal. For instance, the program under the control of dtach would not be affected by the terminal being disconnected for some reason.

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
