# zmx

The goal of this project is to create a way to attach and detach terminal sessions without killing the underlying linux process.

When researching `zmx`, also read the @README.md in the root of this project directory to learn more about the features, documentation, prior art, etc.

## tech stack

- `zig` v0.15.1
- `libghostty-vt` for terminal escape codes and terminal state management
- `libxev` for handling single-threaded, non-blocking, async flow control
- `clap` for building the cli
- `systemd` for background process supervision

## commands

- **Build:** `zig build`
- **Build Check (Zig)**: `zig build check`
- **Test (Zig):** `zig build test`
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`

## find any library API definitions

Before trying anything else, run the `zigdoc` command to find an API with documentation:

```
zigdoc {symbol}
# examples
zigdoc ghostty-vt
zigdoc clap
zigdoc xev
zigdoc std.ArrayList
zigdoc std.mem.Allocator
zigdoc std.http.Server
```

Only if that doesn't work should you grep the project dir.

## find libxev source code

To inspect the source code for libxev, look inside the `libxev_src` folder.

## find zig std library source code

To inspect the source code for zig's standard library, look inside the `zig_std_src` folder.

## find ghostty library source code

To inspect the source code for zig's standard library, look inside the `ghostty_src` folder.

## Issue Tracking

We use bd (beads, https://github.com/steveyegge/beads) for issue tracking instead of Markdown TODOs or external tools.

### Quick Reference

```bash
# Find ready work (no blockers)
bd ready --json

# Create new issue
bd create "Issue title" -t bug|feature|task -p 0-4 -d "Description" --json

# Create with explicit ID (for parallel workers)
bd create "Issue title" --id worker1-100 -p 1 --json

# Update issue status
bd update <id> --status in_progress --json

# Link discovered work (old way)
bd dep add <discovered-id> <parent-id> --type discovered-from

# Create and link in one command (new way)
bd create "Issue title" -t bug -p 1 --deps discovered-from:<parent-id> --json

# Complete work
bd close <id> --reason "Done" --json

# Show dependency tree
bd dep tree <id>

# Get issue details
bd show <id> --json

# Import with collision detection
bd import -i .beads/issues.jsonl --dry-run             # Preview only
bd import -i .beads/issues.jsonl --resolve-collisions  # Auto-resolve
```

### Workflow

1. **Check for ready work**: Run `bd ready` to see what's unblocked
1. **Claim your task**: `bd update <id> --status in_progress`
1. **Work on it**: Implement, test, document
1. **Discover new work**: If you find bugs or TODOs, create issues:
   - Old way (two commands): `bd create "Found bug in auth" -t bug -p 1 --json` then `bd dep add <new-id> <current-id> --type discovered-from`
   - New way (one command): `bd create "Found bug in auth" -t bug -p 1 --deps discovered-from:<current-id> --json`
1. **Complete**: `bd close <id> --reason "Implemented"`
1. **Export**: Changes auto-sync to `.beads/issues.jsonl` (5-second debounce)

### Issue Types

- `bug` - Something broken that needs fixing
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature composed of multiple issues
- `chore` - Maintenance work (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (nice-to-have features, minor bugs)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Dependency Types

- `blocks` - Hard dependency (issue X blocks issue Y)
- `related` - Soft relationship (issues are connected)
- `parent-child` - Epic/subtask relationship
- `discovered-from` - Track issues discovered during work

Only `blocks` dependencies affect the ready work queue.
