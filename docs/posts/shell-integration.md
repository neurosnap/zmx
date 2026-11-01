---
title: Shell integration
description: Configure your shell prompt, environment tracking, completions, and session picker
keywords: [zmx, shell, prompt, completions, environment, fzf]
toc: 3
---

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

## environment variables

A session's environment is initialized when the session is created. When re-attaching from a new terminal or a different SSH connection, environment variables describing the client connection (such as `SSH_AUTH_SOCK`, `DISPLAY`, or terminal remote control variables like `KITTY_LISTEN_ON`, `KITTY_PID`, `KITTY_WINDOW_ID`) become outdated in the running shell.

`zmx` tracks these environment variables from attaching clients. You can inspect the current leader client's environment with `zmx print-env`:

```bash
# Print all tracked environment variables (set variables as KEY=VALUE, unset as -KEY)
zmx print-env .
zmx print-env dev

# Print POSIX shell commands (export ... / unset ...) suitable for eval
zmx print-env -s .

# Print a specific variable value
zmx print-env . SSH_AUTH_SOCK
```

You can automatically update your shell environment before each prompt:

### bash

Add to `~/.bashrc`:

```bash
_zmx_env_hook() {
  if [[ -n $ZMX_SESSION ]]; then
    eval "$(zmx print-env -s .)"
  fi
}
PROMPT_COMMAND="_zmx_env_hook${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
```

### zsh

Add to `~/.zshrc`:

```zsh
precmd() {
  if [[ -n $ZMX_SESSION ]]; then
    eval "$(zmx print-env -s .)"
  fi
}
```

### fish

Add to `~/.config/fish/config.fish`:

```fish
function _zmx_env_hook --on-event fish_prompt
  if test -n "$ZMX_SESSION"
    for line in (zmx print-env .)
      if string match -q -- "-*" $line
        set -e (string sub -s 2 $line)
      else
        set -gx (string split -m 1 "=" $line)
      end
    end
  end
end
```

### configuring tracked variables

By default, `zmx` tracks:

- `DISPLAY`
- `SSH_AUTH_SOCK`
- `SSH_AGENT_PID`
- `SSH_CONNECTION`
- `WINDOWID`
- `XAUTHORITY`
- `KITTY_LISTEN_ON`
- `KITTY_PID`
- `KITTY_WINDOW_ID`

You can customize this list by setting `ZMX_TRACK_ENV` to a comma-separated list of variable names:

```bash
export ZMX_TRACK_ENV="DISPLAY,SSH_AUTH_SOCK,GPG_AGENT_INFO"
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

### yash

Add this to your `~/.config/yash/rc`:

```sh
if command -v zmx > /dev/null 2>&1; then
  eval "$(zmx completions yash)"
fi
```

Or save as an autoloaded script in your completion directory:

```sh
zmx completions yash > ~/.config/yash/completion/zmx
```

### nu

Add this to your Nushell config (`config.nu`):

```nu
use ("~/.cache/zmx/completions.nu" | path expand)
# Or generate dynamically:
zmx completions nu | save -f ~/.cache/zmx/completions.nu
```

## session picker

An interactive session picker using [fzf](https://github.com/junegunn/fzf) to attach to existing sessions, preview scrollback, or create new sessions.

- **Enter** selects a matched session (or creates one if no sessions exist)
- **Ctrl-N** creates a new session using the typed query, even when a fuzzy match is highlighted

### bash and zsh

```bash
zmx-select() {
  local display
  local prefix="${ZMX_SESSION_PREFIX:-}"
  display=$(zmx list 2>/dev/null | while IFS=$'\t' read -r name pid clients created dir; do
    name=${name#*name=}
    pid=${pid#*pid=}
    clients=${clients#*clients=}
    dir=${dir#*start_dir=}
    if [[ -n "$prefix" ]]; then
      [[ "$name" == "$prefix"* ]] || continue
      name=${name#"$prefix"}
    fi
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

Run `zmx-select` directly or launch it from your shell rc file when outside a session. With `&& exit`, detaching or exiting the session closes the SSH connection, while `ctrl+c` in the picker drops into a regular shell:

```bash
if command -v zmx &> /dev/null && command -v fzf &> /dev/null && [[ -z "$ZMX_SESSION" ]]; then
  zmx-select && exit
fi
```

### alternative: gentle hint (server use)

On shared servers where you don't want `fzf` to launch on every login, print a reminder when active sessions exist:

```bash
if command -v zmx &> /dev/null && [[ -z "$ZMX_SESSION" ]]; then
  local count
  count=$(zmx ls --short 2>/dev/null | wc -l)
  if [[ "$count" -gt 0 ]]; then
    echo "zmx: $count session(s) active (run zmx-select to attach)" >&2
  fi
fi
```
