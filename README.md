<h1>
<p align="center">
  <img src="./docs/logo.png" alt="Logo" width="128">
  <br>zmx
</h1>
<p align="center">
  Session persistence for terminal processes.
  <br />
  <a href="https://zmx.sh">Docs</a>
  ·
  <a href="https://bower.sh/you-might-not-need-tmux">You might not need tmux</a>
  ·
  Sponsored by <a href="https://pico.sh">pico.sh</a>
</p>

## features

- Persist terminal shell sessions
- Ability to attach and detach from a shell session without killing it
- Native terminal scrollback
- Multiple clients can connect to the same session
- Re-attaching to a session restores previous terminal state and output
- Send commands to a session without attaching to it
- Print scrollback history of a terminal session in plain text
- Works on mac and linux
- This project does **NOT** provide windows, tabs, or splits

[demo video](https://youtu.be/UIXj0_rhPgI?si=NolwGR4GTCQOESy6)

## install

### binaries

- https://zmx.sh/a/zmx-0.4.2-linux-aarch64.tar.gz
- https://zmx.sh/a/zmx-0.4.2-linux-x86_64.tar.gz
- https://zmx.sh/a/zmx-0.4.2-macos-aarch64.tar.gz
- https://zmx.sh/a/zmx-0.4.2-macos-x86_64.tar.gz

### homebrew

```bash
brew install neurosnap/tap/zmx
```

### packages (unofficial)

- [Alpine Linux](https://pkgs.alpinelinux.org/package/edge/testing/x86_64/zmx)
- [Arch AUR tracking releases](https://aur.archlinux.org/packages/zmx)
- [Arch AUR tracking git](https://aur.archlinux.org/packages/zmx-git)
- [openSUSE Tumbleweed](https://software.opensuse.org/package/zmx)
- [Gentoo (overlay)](https://codeberg.org/samuelhautamaki/samuelhautamaki-gentoo)
- [zmx-rpm packaging](https://github.com/engie/zmx-rpm/)

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
> We recommend closing the terminal window to detach from the session but you can also press `ctrl+\` or run `zmx detach`.

```
zmx - session persistence for terminal processes

Usage: zmx <command> [args...]

Commands:
  [a]ttach <name> [command...]             Attach to session, creating if needed
  [r]un <name> [-d] [--fish] [command...]  Send command without attaching
  [wr]ite <name> <file_path>               Write stdin to file_path through the session
  [d]etach                                 Detach all clients (ctrl+\\ for current client)
  [l]ist [--short]                         List active sessions
  [k]ill <name>... [--force]               Kill session and all attached clients
  [hi]story <name> [--vt|--html]           Output session scrollback
  [w]ait <name>...                         Wait for session tasks to complete
  [t]ail <name>...                         Follow session output
  [c]ompletions <shell>                    Shell completions (bash, zsh, fish)
  [v]ersion                                Show version
  [h]elp                                   Show this help

Attach:
  This will spawn a login $SHELL with a PTY.  You can provide a
  command instead of creating a shell.

  Examples:
    zmx attach dev
    zmx attach dev vim

History:
  This should generally be used with `tail` to print the last lines
  of the session's scrollback history.

  Examples:
    zmx history <session> | tail -100

Run:
  Commands are passed as-is; do not wrap in quotes.
  Commands run sequentially; do not send multiple in parallel.
  Avoid interactive programs (pagers, editors, prompts) -- they hang.

  `-d` will detach from the calling terminal. Use `wait` to track
  its status.

  `--fish` is required when the session runs fish shell.

  If the command hangs, send Ctrl+C to recover:
    zmx run <session> $'\\x03'

  Examples:
    zmx run dev ls
    zmx run dev --fish ls src
    zmx run dev zig build
    zmx run dev grep -r TODO src
    zmx run dev git -c core.pager=cat diff

Write:
  Writes stdin to file_path inside the session. Works over SSH.
  file_path can be absolute or relative to the session shell's cwd.
  Requires base64 and printf in the remote environment.
  Large files are chunked automatically (~48KB per chunk).
  File path must not contain single quotes.

  Examples:
    echo "hello" | zmx write dev /tmp/hello.txt
    cat main.zig | zmx write dev src/main.zig

Wait:
  Used with a detached run task to track its status.  Multiple
  sessions can be provided.

  Examples:
    zmx run -d dev sleep 10
    zmx wait dev
    zmx wait dev other

Environment variables:
  SHELL                Default shell for new sessions
  ZMX_DIR              Socket directory (priority 1)
  XDG_RUNTIME_DIR      Socket directory (priority 2)
  TMPDIR               Socket directory (priority 3)
  ZMX_SESSION          Session name (injected automatically)
  ZMX_SESSION_PREFIX   Prefix added to all session names
  ZMX_DIR_MODE         Sets mode for socket and log directories (octal, defaults to 0750)
  ZMX_LOG_MODE         Sets mode for log files (octal, defaults to 0640)
```

## shell prompt

When you attach to a `zmx` session, we don't provide any indication that you are inside `zmx`. We do provide an environment variable `ZMX_SESSION` which contains the session name.

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

### bash and zsh

Depending on the shell, place this in either `.bashrc` or `.zshrc`:

```bash
if [[ -n $ZMX_SESSION ]]; then
  export PS1="[$ZMX_SESSION] ${PS1}"
fi
```

### powerlevel10k zsh theme

[powerlevel10k](https://github.com/romkatv/powerlevel10k) is a theme for zsh that overwrites the default prompt statusline.

Place this in `.zshrc`:

```bash
function prompt_my_zmx_session() {
  if [[ -n $ZMX_SESSION ]]; then
    p10k segment -b '%k' -f '%f' -t "[$ZMX_SESSION]"
  fi
}
POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS+=my_zmx_session
```

### oh-my-posh

[oh-my-posh](https://ohmyposh.dev) is a popular shell themeing and prompt engine. This code will display an icon and session name as part of the prompt if (and only if) you have zmx active:

```toml
[[blocks.segments]]
   template = '{{ if .Env.ZMX_SESSION }} {{ .Env.ZMX_SESSION }}{{ end }}'
   foreground = 'p:orange'
   background = 'p:black'
   type = 'text'
   style = 'plain'
```

### Starship

[Starship](https://starship.rs) is a popular shell themeing and prompt engine. This code will display an icon and session name as part of the prompt if (and only if) you have zmx active:

```toml
format = """
${env_var.ZMX_SESSION}\
...
"""

[env_var.ZMX_SESSION]
symbol = " "
format = "[$symbol$env_value]($style) "
description = "zmx session name"
style = "bold magenta"
```

## shell completion

Shell auto-completion for `zmx` commands and session names can be enabled using the `completions` subcommand. Once configured, you'll get auto-complete for both local `zmx` commands and sessions:

```bash
ssh remote-server zmx attach session-na<TAB>
# <- auto-complete suggestions appear here
```

> NOTICE: when installing `zmx` with `homebrew` completions are automatically installed.

### bash

Add this to your `.bashrc` file:

```bash
if command -v zmx &> /dev/null; then
  eval "$(zmx completions bash)"
fi
```

### zsh

Add this to your `.zshrc` file:

```zsh
if command -v zmx &> /dev/null; then
  eval "$(zmx completions zsh)"
fi
```

### fish

Add this to `~/.config/fish/completions/zmx.fish`:

```fish
if type -q zmx
  zmx completions fish | source
end
```

## session picker

You can add an interactive session picker to your shell that lets you fuzzy-find existing sessions, preview their scrollback history, or create new ones — all from a single prompt. This is especially useful for remote SSH workflows: add it to your shell startup so that connecting to a machine immediately presents the picker.

Requires [fzf](https://github.com/junegunn/fzf).

- **Enter** selects a matched session (or creates one if no sessions exist)
- **Ctrl-N** creates a new session using the typed query, even when a fuzzy match is highlighted

<details>
<summary>bash and zsh</summary>

```bash
zmx-select() {
  local display
  display=$(zmx list 2>/dev/null | while IFS=$'\t' read -r name pid clients created dir; do
    name=${name#session_name=}
    pid=${pid#pid=}
    clients=${clients#clients=}
    dir=${dir#started_in=}
    printf "%-20s  pid:%-8s  clients:%-2s  %s\n" "$name" "$pid" "$clients" "$dir"
  done)

  local output query key selected session_name
  output=$({ [[ -n "$display" ]] && echo "$display"; } | fzf \
    --print-query \
    --expect=ctrl-n \
    --height=80% \
    --reverse \
    --prompt="zmx> " \
    --header="Enter: select | Ctrl-N: create new" \
    --preview='zmx history {1}' \
    --preview-window=right:60%:follow \
  )
  local rc=$?

  query=$(echo "$output" | sed -n '1p')
  key=$(echo "$output" | sed -n '2p')
  selected=$(echo "$output" | sed -n '3p')

  if [[ "$key" == "ctrl-n" && -n "$query" ]]; then
    session_name="$query"
  elif [[ $rc -eq 0 && -n "$selected" ]]; then
    session_name=$(echo "$selected" | awk '{print $1}')
  elif [[ -n "$query" ]]; then
    session_name="$query"
  else
    return 130
  fi

  zmx attach "$session_name"
}
```

You can call `zmx-select` manually, bind it to a key, or auto-launch it on shell startup when outside a zmx session. With `&& exit`, the normal flow becomes: connect via SSH → pick a session → work → detach or exit the session → SSH disconnects automatically. Cancelling the picker with **Ctrl-C** drops you into a regular shell as an escape hatch.

```bash
if command -v zmx &> /dev/null && command -v fzf &> /dev/null && [[ -z "$ZMX_SESSION" ]]; then
  zmx-select && exit
fi
```

</details>

## session prefix

We allow users to set an environment variable `ZMX_SESSION_PREFIX` which will prefix the name of the session for all commands. This means if that variable is set, every command that accepts a session will be prefixed with it.

```bash
export ZMX_SESSION_PREFIX="d."
zmx a runner # ZMX_SESSION=d.runner
zmx a tests  # ZMX_SESSION=d.tests
zmx k tests  # kills d.tests
zmx wait     # suspends until all tasks prefixed with "d." are complete
```

## philosophy

The entire argument for `zmx` instead of something like `tmux` that has windows, panes, splits, etc. is that job should be handled by your os window manager. By using something like `tmux` you now have redundant functionality in your dev stack: a window manager for your os and a window manager for your terminal. Further, in order to use modern terminal features, your terminal emulator **and** `tmux` need to have support for them. This holds back the terminal enthusiast community and feature development.

Instead, this tool specifically focuses on session persistence and defers window management to your os wm.

## ssh workflow

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
ash d.dotifles
```

Wow! Now you can setup all your os tiling windows how you like them for your project and have as many windows as you'd like, almost replicating exactly what `tmux` does but with native windows, tabs, splits, and scrollback! It also has the added benefit of supporting all the terminal features your emulator supports, no longer restricted by what `tmux` supports.

The end-game here would be to leverage your window manager's ability to automatically arrange your windows for each project with a single command.

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

We store global logs for cli commands in `{socket_dir}/logs/zmx.log`. We store session-specific logs in `{socket_dir}/logs/{session_name}.log`. Right now they are enabled by default and cannot be disabled. The idea here is to help with initial development until we reach a stable state.

## a note on configuration

We are evaluating what should be configurable and what should not. Every configuration option is a burden for us maintainers. For example, being able to change the default detach shortcut is difficult in a terminal environment.

## a smol contract

- Write programs that solve a well defined problem.
- Write programs that behave the way most users expect them to behave.
- Write programs that a single person can maintain.
- Write programs that compose with other smol tools.
- Write programs that can be finished.

## known issues

- When upgrading versions of `zmx` where we make changes to the underlying IPC communication, it will kill all your sessions because it cannot communicate through the daemon socket properly
- Terminal state restoration with nested `zmx` sessions through SSH: host A `zmx` -> SSH -> host B `zmx`
  - Specifically cursor position gets corrupted
- When re-attaching and kitty keyboard mode was previously enable, we try to re-send that CSI query to re-enable it
  - Some programs don't know how to handle that CSI query (e.g. `psql`) so when you type it echos kitty escape sequences erroneously

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

Below is a list of projects that inspired me to build this project. Architecturally, `zmx` uses aspects of both projects. For example, `shpool` inspired the idea of having libghostty restore the terminal state on reattach. Abduco inspired the idea of one daemon (and unix socket) per session.

### shpool

https://github.com/shell-pool/shpool

`shpool` is a service that enables session persistence by allowing the creation of named shell sessions owned by `shpool` so that the session is not lost if the connection drops.

### abduco

https://github.com/martanne/abduco

abduco provides session management (i.e. it allows programs to be run independently from its controlling terminal). Together with dvtm it provides a simpler alternative to tmux or screen.

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

## community tools

- [zsm](https://github.com/mdsakalu/zmx-session-manager) — TUI session manager for zmx. List, preview, filter, and kill sessions from an interactive terminal UI.
- [zmosh](https://github.com/mmonad/zmosh) — A fork of zmx that adds encrypted UDP auto-reconnect for remote sessions (like mosh).
