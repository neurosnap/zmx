# zmx

session persistence for terminal processes

## features

- Persist terminal shell sessions (pty processes)
- Ability to attach and detach from a shell session without killing it
- Supports all the terminal features that the client's terminal emulator supports
- Native terminal scrollback
- Manage shell sessions
- Multiple clients can connect to the same session
- Each session creates its own unix socket file `/tmp/zmx/`
- Re-attaching to a session restores previous terminal state and output
- The `daemon` and client processes communicate via a unix socket
- This project does **NOT** provide windows, tabs, or window splits
- Works on mac and linux

## usage

- `zmx attach {session_name}` - create or attach to a session
- `zmx detach [{session_name}]` (or Ctrl+\\) - detach all connected clients to session, can be used inside session without providing name
- `zmx list` - list sessions
- `zmx kill {session_name}` kill pty and all clients attached to session

## todo

- [ ] Ability to pass a command to attach `zmx attach mux dvtm`
- [ ] Integrate with `libghostty` to restore terminal state on re-attach
- [ ] How to add debug logs without disrupting active client terminal output
- [ ] Binary distribution (e.g. pkg managers)

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
