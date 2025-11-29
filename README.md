# zmx

session persistence for terminal processes

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
