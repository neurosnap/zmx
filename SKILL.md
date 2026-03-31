---
name: zmx-session
description: This skill provides instructions for collaborative terminal debugging using zmx for session persistence. Use when the user wants to share a terminal session, debug server logs, troubleshoot infrastructure, or work together on a remote host via SSH. Triggers on mentions of "zmx", "shared session", "terminal debugging", or when user wants Claude to see terminal output.
---

# zmx Collaborative Terminal Sessions

## Overview

zmx is a lightweight terminal session persistence tool. It allows detaching from and reattaching to running shell sessions without killing processes. Unlike tmux, it focuses only on session persistence -- no windows, panes, or splits.

This skill covers using zmx for collaborative debugging where Claude can directly view session history and execute commands.

Run `zmx help` to understand the commands and when to run them.

## Session Setup

The user starts a zmx session and works within it:

```bash
# Create or attach to a named session
zmx attach <session-name>
```

Naming convention suggestion: use descriptive names like `debug-prod`, `k8s-issue`, `logs-api`.

## Viewing Session Context

Claude can directly view the terminal history without user intervention:

```bash
# List active sessions
zmx list

# View recent scrollback from a session (always pipe to tail to limit context)
zmx history <session-name> | tail -200
```

These are read-only commands—run them freely to understand what's happening.

If `zmx list` shows no sessions or the expected session is missing, inform the user and ask them to start or verify their zmx session.

## Command Execution Protocol

**Always ask permission before running commands that execute in the user's session.**

To execute a command in a running session without attaching:

```bash
zmx run <session-name> <command>
```

Then you can wait for the task to complete by running:

```bash
zmx wait <session-name>
```

And you can track the exit code by running:

```bash
zmx list | grep <session-name>
```

Example workflow:

1. User tells Claude the session name and describes the issue
1. Claude runs `zmx history <session-name> | tail -200` to see context
1. Claude analyzes and proposes a command
1. User approves
1. Claude runs via `zmx run <session-name> <command>`
1. Claude runs `zmx history <session-name> | tail -50` to see the output (zmx run does not return output directly -- it goes to the session's scrollback)
1. Claude evaluates the output and provides analysis
1. Repeat steps 3-7 as needed until the issue is resolved
