![logo](./logo.png)

# zmx

session persistence for terminal processes

Reason for this tool: [You might not need `tmux`](https://bower.sh/you-might-not-need-tmux)

## features

- Persist terminal shell sessions (pty processes)
- Ability to attach and detach from a shell session without killing it
- Native terminal scrollback
- Manage shell sessions
- Multiple clients can connect to the same session
- Re-attaching to a session restores previous terminal state and output
- Works on mac and linux
- This project does **NOT** provide windows, tabs, or window splits

## impl

- The `daemon` and client processes communicate via a unix socket
- Each session creates its own unix socket file `/tmp/zmx/*`
- We restore terminal state and output using `libghostty-vt`

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

When you attach to a zmx session, we don't provide any indication that you are inside zmx. We do provide an environment variable `ZMX_SESSION` which contains the session name.

We recommend checking for that env var inside your prompt and displaying some indication there.

### fish

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

todo.

## philosophy

The entire argument for `zmx` instead of something like `tmux` that has windows, panes, splits, etc. is that job should be handled by your os window manager.  By using something like `tmux` you now have redundent functionality in your dev stack: a tiling manager for your os windows and a tiling manager for your terminal windows.

Instead, we focus this tool specifically on session persistence and defer window management to your os wm.

## ssh workflow

Using `zmx` with `ssh` is a first-class citizen.  Instead of sshing into your remote system with a single terminal and have `n` tmux pandes, you open `n` number of terminals open and ssh into your remote system `n` number of times.  This might sound like a downgrade, but there are tools to make this a delightful workflow.

First, create an ssh config entry for your remote dev server:

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

This will create or attach to each session and since we are using `ControlMaster` the same `ssh` connection is reused for near-instant connection times.

Now you can use the [`autossh`](https://linux.die.net/man/1/autossh) tool to make your ssh connections auto-reconnect.  For example, if you have a laptop and close/open your laptop lid it will automatically reconnect all your ssh connections:

```bash
autossh -M 0 d.term
```

Or create an `alias`/`abbr`:

```fish
abbr -a ash "autossh -M 0"
```

```bash
ash d.term
ash d.irc
ash d.pico
ash d.dotifles
```

Wow!  Now you can setup all your os tiling windows how you like them for your project and have as many windows as you'd like, almost replicating exactly what `tmux` used to do with a slightly different workflow.

## socket file location

Each session gets its own unix socket file. Right now, the default location is `/tmp/zmx`. At the moment this is not configurable.

## debugging

We store global logs for cli commands in `/tmp/zmx/logs/zmx.log`. We store session-specific logs in `/tmp/zmx/logs/{session_name}.log`. These logs rotate to `.old` after 5MB. At the moment this is not configurable.

## a note on configuration

At this point, nothing is configurable.  We are evaluating what should be configurable and what should not.  Every configuration option is a burden for us maintainers.  For example, being able to change the default detach shortcut is difficult in a terminal environment.

## a smol contract

- Write programs that solve a well defined problem.
- Write programs that behave the way most users expect them to behave.
- Write programs that a single person can maintain.
- Write programs that compose with other smol tools.
- Write programs that can be finished.

## todo

- `bug`: unix socket files not always getting removed properly
- `bug`: remove log files when closing session
- `feat`: binary distribution (e.g. `aur`, `ppa`, `apk`, `brew`)

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
