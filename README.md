# zmx (KnickKnackLabs fork)

Community fork of [neurosnap/zmx](https://github.com/neurosnap/zmx) — session persistence for terminal processes.

## Why this fork?

zmx is great. This fork exists for two reasons:

1. **Release binaries** — upstream publishes tags but not GitHub releases with prebuilt binaries. We build and publish binaries for macOS (aarch64, x86_64) and Linux (aarch64, x86_64) on every release.
2. **Bug fixes** — small targeted patches that we've contributed (or plan to contribute) upstream.

We track upstream closely and keep our patch set minimal. See [Patches](#patches) below.

## Install

### From GitHub releases

```bash
# macOS (Apple Silicon)
curl -sL https://github.com/KnickKnackLabs/zmx/releases/latest/download/zmx-macos-aarch64.tar.gz | tar xz -C ~/.local/bin/

# macOS (Intel)
curl -sL https://github.com/KnickKnackLabs/zmx/releases/latest/download/zmx-macos-x86_64.tar.gz | tar xz -C ~/.local/bin/

# Linux (aarch64)
curl -sL https://github.com/KnickKnackLabs/zmx/releases/latest/download/zmx-linux-aarch64.tar.gz | tar xz -C ~/.local/bin/

# Linux (x86_64)
curl -sL https://github.com/KnickKnackLabs/zmx/releases/latest/download/zmx-linux-x86_64.tar.gz | tar xz -C ~/.local/bin/
```

### Via mise

```toml
[tools]
"github:KnickKnackLabs/zmx" = "latest"
```

## Patches

Current patches on top of upstream (see `git log upstream..main`):

| Patch | Status | Description |
|-------|--------|-------------|
| `fix(build): disable ghostty xcframework` | fork-only | Pass `emit-xcframework=false` to ghostty dependency. Fixes build on macOS without full Xcode (only Command Line Tools). |
| `fix(daemon): close inherited FDs after fork` | PR pending | Close FDs 3+ in the forked daemon process. Fixes test harnesses (bats, etc.) hanging indefinitely because the daemon inherits and holds their internal FDs. |

## Branch structure

- **`upstream`** — exact mirror of `neurosnap/zmx` main. No local changes.
- **`main`** — our patches rebased on top of upstream. This is what we build and release from.

## Building from source

Requires [Zig](https://ziglang.org/) 0.15.2+.

```bash
zig build -Doptimize=ReleaseSafe
# Binary at zig-out/bin/zmx
```

On macOS, you may need to codesign the binary:

```bash
codesign -s - zig-out/bin/zmx
```

## Usage

See the [upstream README](https://github.com/neurosnap/zmx) for full documentation. The CLI is unchanged:

```
zmx run <name> [command...]      # Send command without attaching
zmx attach <name> [command...]   # Attach to session (creates if needed)
zmx list [--short]               # List active sessions
zmx kill <name>...               # Kill session(s)
zmx history <name> [--vt|--html] # Session scrollback
zmx wait <name>...               # Wait for tasks to complete
zmx detach                       # Detach from current session
```

## License

MIT — same as upstream.
