# nmux — Currently Supported Features

## Session Management
- **Persist shell sessions** — detach without killing the underlying process
- **Multiple clients** — concurrent readers/writers per session; last-keystroke leader policy determines resize authority
- **Session switching** — attach, then switch to another session from within a session
- **Session globbing** — `nmux kill "test*"`, `nmux wait "*"` with `*` suffix wildcard
- **Session prefix** — `NMUX_SESSION_PREFIX` env var prepended to every session name

## Commands

| Command | Aliases | Purpose |
|---|---|---|
| `nmux attach` | `a` | Create/attach session, optionally with initial command |
| `nmux run` | `r` | Send command without attaching; synchronous by default, `-d` for detached. Uses `bash` for exit-code tracking. |
| `nmux send` | `s` | Send raw bytes to PTY — no completion marker, no auto-newline |
| `nmux print` | `p` | Send raw bytes to client stdout |
| `nmux write` | `wr` | Pipe stdin → base64 → chunked printf through PTY to write file inside session |
| `nmux detach` | `d` | Detach all clients (`ctrl+\` detaches current client) |
| `nmux list` | `l`, `ls` | List sessions; `--short` prints names only. Shows arrow for current session, start_dir, cmd, clients, created. |
| `nmux kill` | `k` | Kill sessions; `--force` cleans stale sockets. Multi-arg, prefix-globbing. |
| `nmux history` | `hi` | Scrollback output: `--vt` (raw ANSI), `--html`, or plain text |
| `nmux wait` | `w` | Block until all matching tasks complete. Tails last 20 lines of failed tasks. |
| `nmux tail` | `t` | Read-only follow of session output. Strips ANSI escapes. |
| `nmux completions` | `c` | Generate completions for bash, zsh, fish, nu |
| `nmux version` | `v` | Show nmux + ghostty-vt versions, socket dir, log dir |
| `nmux help` | `h` | Usage with examples |

## Terminal & IPC
- **Ghostty-vt engine** — full VT state machine for scrollback capture, terminal restoration on re-attach (scrollback + cursor + modes)
- **OSC 133;A `redraw=0` injection** — prevents prompt loss on resize by telling outer terminal not to expect shell redraw
- **DA query response** — daemon answers Device Attribute queries when no client is attached
- **Non-exhaustive IPC `Tag`** — backward-compatible wire protocol; old daemons ignore unknown tags
- **Wire protocol freeze tests** — `@sizeOf(Info)` and `Tag` values locked by tests to prevent accidental breakage

## Configuration
- `NMUX_DIR` — override socket dir
- `XDG_RUNTIME_DIR` — socket dir fallback, takes precedence over `TMPDIR`
- `TMPDIR` — socket dir fallback over `/tmp`
- `NMUX_SESSION_PREFIX` — prefix all session names
- `NMUX_DIR_MODE` / `NMUX_LOG_MODE` — custom permissions
- `NMUX_SESSION` — env var set inside sessions (for prompt customization)

## Platform
- Linux + macOS (x86_64, aarch64)
- Shell completions: bash, zsh, fish, nu
- Nix flake, Homebrew, Docker

## Design Decisions
1. **No window/tab/split management** — defers to OS window manager; scope is session attach/detach only
2. **Daemon-per-session** — each named session is an independent daemon process with its own Unix socket
3. **Client leader policy** — only the last client to send user-input bytes controls resize; prevents read-only tail clients from resizing the PTY
4. **`nmux run` uses bash** — bash (not `$SHELL`) for predictable `$?` exit-code tracking across edge cases
5. **`nmux tail` strips ANSI** — plain-text output by default
6. **`nmux run` synchronous** — tails session output by default; pass `-d` for fire-and-forget
7. **Socket path length guard** — validates session name fits `sockaddr_un` before creating socket
