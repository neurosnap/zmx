#!/usr/bin/env bats
# Session lifecycle tests for nmux.
#
# These tests create real nmux sessions — forking daemon processes, allocating
# PTYs, running commands. Without the inherited-FD close fix, every test that
# calls `nmux run` would hang indefinitely because bats waits for its internal
# FDs (3+) to close, and the daemon inherits them.
#
# If this test suite completes at all, the FD fix is working.
#
# All `run` invocations use `-d` (detached) because `nmux run` blocks until
# the command completes, and sessions outlive their initial command.
# Note: `-d` must come after the session name (nmux run <name> -d <cmd>).

load test_helper

# ============================================================================
# Session creation
# ============================================================================

@test "run: creates a session" {
  run "$NMUX" run test-create -d echo hello
  [ "$status" -eq 0 ]
  [[ "$output" == *"session \"test-create\" created"* ]]

  wait_for_session test-create
  run "$NMUX" list --short
  [[ "$output" == "test-create" ]]
}

@test "run: sends command to existing session" {
  "$NMUX" run test-send -d echo first
  wait_for_session test-send

  run "$NMUX" run test-send -d echo second
  [ "$status" -eq 0 ]
  [[ "$output" == *"command sent"* ]]
  # Should NOT say "created" — session already exists
  [[ "$output" != *"created"* ]]
}

@test "run: blocking returns after command completes" {
  run timeout 5 env SHELL=/bin/bash "$NMUX" run test-blocking echo hello
  [ "$status" -eq 0 ]
  [[ "$output" == *"session \"test-blocking\" created"* ]]
}

@test "run: requires a command argument" {
  run "$NMUX" run test-nocmd
  [ "$status" -ne 0 ]
}

@test "run --help shows help without creating a session" {
  run "$NMUX" run --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]

  run "$NMUX" list --short
  [ "$status" -eq 0 ]
  [[ "$output" != *"--help"* ]]
}

@test "subcommands handle --help and -h without side effects" {
  for cmd in attach send print write kill wait tail history list completions; do
    run "$NMUX" "$cmd" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]

    run "$NMUX" "$cmd" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
  done

  run "$NMUX" list --short
  [ "$status" -eq 0 ]
  [[ "$output" != *"--help"* ]]
  [[ "$output" != *"-h"* ]]
}

# ============================================================================
# Send (raw PTY input)
# ============================================================================

@test "send: does not append CR by default" {
  "$NMUX" run test-send-raw -d echo ready
  wait_for_session test-send-raw
  sleep 0.5

  # Send text without \r — it should NOT execute as a command
  run "$NMUX" send test-send-raw "partial-text"
  [ "$status" -eq 0 ]
}

@test "send: requires a session name" {
  run "$NMUX" send
  [ "$status" -ne 0 ]
}

@test "send: requires text argument" {
  "$NMUX" run test-send-notext -d true
  wait_for_session test-send-notext

  run "$NMUX" send test-send-notext
  [ "$status" -ne 0 ]
}

@test "send: accepts piped stdin" {
  "$NMUX" run test-send-pipe -d echo ready
  wait_for_session test-send-pipe
  sleep 0.5

  run bash -c 'printf "echo piped-marker-xyz789\r" | "$0" send test-send-pipe' "$NMUX"
  [ "$status" -eq 0 ]

  sleep 0.5
  run "$NMUX" history test-send-pipe
  [[ "$output" == *"piped-marker-xyz789"* ]]
}

# ============================================================================
# Session listing
# ============================================================================

@test "list: no sessions returns cleanly" {
  run "$NMUX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sessions found"* ]]
}

@test "ls aliases list" {
  run "$NMUX" ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sessions found"* ]]
}

@test "list: shows session details" {
  "$NMUX" run test-list -d echo hello
  wait_for_session test-list

  run "$NMUX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-list"* ]]
  [[ "$output" == *"pid="* ]]
}

@test "list --short: shows only session names" {
  "$NMUX" run test-short-a -d true
  "$NMUX" run test-short-b -d true
  wait_for_session test-short-a
  wait_for_session test-short-b

  run "$NMUX" list --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-short-a"* ]]
  [[ "$output" == *"test-short-b"* ]]
}

@test "list --short: empty when no sessions" {
  run "$NMUX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================================
# Session kill
# ============================================================================

@test "kill: removes a session" {
  "$NMUX" run test-kill -d true
  wait_for_session test-kill

  run "$NMUX" kill test-kill
  [ "$status" -eq 0 ]
  [[ "$output" == *"killed session test-kill"* ]]

  run "$NMUX" list --short
  [[ "$output" != *"test-kill"* ]]
}

@test "kill: multiple sessions at once" {
  "$NMUX" run kill-a -d true
  "$NMUX" run kill-b -d true
  wait_for_session kill-a
  wait_for_session kill-b

  run "$NMUX" kill kill-a kill-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"killed session kill-a"* ]]
  [[ "$output" == *"killed session kill-b"* ]]
}

@test "kill --force: removes socket file for dead session" {
  "$NMUX" run test-force -d true
  wait_for_session test-force

  # Get the daemon PID and kill it directly (simulating a crash)
  local pid
  pid=$("$NMUX" list 2>/dev/null | grep test-force | sed 's/.*pid=\([0-9]*\).*/\1/')
  if [[ -n "$pid" ]]; then
    kill -9 "$pid" 2>/dev/null || true
    sleep 0.5
  fi

  # Regular kill may fail on the dead session; --force cleans up
  run "$NMUX" kill --force test-force
  [ "$status" -eq 0 ]
}

# ============================================================================
# Session isolation (NMUX_DIR)
# ============================================================================

@test "NMUX_DIR isolation: sessions in one dir are invisible to another" {
  "$NMUX" run test-isolated -d true
  wait_for_session test-isolated

  # A different NMUX_DIR should see no sessions
  local other_dir="$BATS_TEST_TMPDIR/nmux-other"
  mkdir -p "$other_dir"
  run env NMUX_DIR="$other_dir" "$NMUX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================================
# History
# ============================================================================

@test "history: captures session output" {
  "$NMUX" run test-hist -d echo "bats-marker-xyzzy"
  wait_for_session test-hist
  sleep 0.5  # give the command time to produce output

  run "$NMUX" history test-hist
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats-marker-xyzzy"* ]]
}

# ============================================================================
# Wait
# ============================================================================

@test "wait: returns after session command completes" {
  "$NMUX" run test-wait -d echo done
  wait_for_session test-wait
  sleep 1  # give the command time to finish

  # `wait` should return once the command finishes
  run timeout 10 "$NMUX" wait test-wait
  [ "$status" -eq 0 ]
}

# ============================================================================
# Rapid session churn (stress test for FD handling)
# ============================================================================

@test "churn: create and kill 5 sessions in sequence" {
  for i in 1 2 3 4 5; do
    "$NMUX" run "churn-$i" -d echo "iteration $i"
    wait_for_session "churn-$i"
    "$NMUX" kill "churn-$i"
  done

  run "$NMUX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}


# ============================================================================
# Print (inject text into terminal state)
# ============================================================================

@test "print: text appears in history" {
  "$NMUX" run test-print-hist -d echo ready
  wait_for_session test-print-hist
  sleep 0.3

  # Caller is responsible for newlines; trailing \r\n ensures the text
  # lands on its own line before SIGWINCH triggers a prompt redraw.
  printf "\r\nbats-print-marker-abc123\r\n" | "$NMUX" print test-print-hist
  sleep 0.3

  run "$NMUX" history test-print-hist
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats-print-marker-abc123"* ]]
}

@test "print: requires a session name" {
  run "$NMUX" print
  [ "$status" -ne 0 ]
}
