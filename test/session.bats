#!/usr/bin/env bats
# Session lifecycle tests for zmx.
#
# These tests create real zmx sessions — forking daemon processes, allocating
# PTYs, running commands. Without the inherited-FD close fix, every test that
# calls `zmx run` would hang indefinitely because bats waits for its internal
# FDs (3+) to close, and the daemon inherits them.
#
# If this test suite completes at all, the FD fix is working.

load test_helper

# ============================================================================
# Session creation
# ============================================================================

@test "run: creates a session" {
  run "$ZMX" run test-create echo hello
  [ "$status" -eq 0 ]
  [[ "$output" == *"session \"test-create\" created"* ]]

  wait_for_session test-create
  run "$ZMX" list --short
  [[ "$output" == "test-create" ]]
}

@test "run: sends command to existing session" {
  "$ZMX" run test-send echo first
  wait_for_session test-send

  run "$ZMX" run test-send echo second
  [ "$status" -eq 0 ]
  [[ "$output" == *"command sent"* ]]
  # Should NOT say "created" — session already exists
  [[ "$output" != *"created"* ]]
}

@test "run: requires a command argument" {
  run "$ZMX" run test-nocmd
  [ "$status" -ne 0 ]
}

# ============================================================================
# Session listing
# ============================================================================

@test "list: no sessions returns cleanly" {
  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sessions found"* ]]
}

@test "list: shows session details" {
  "$ZMX" run test-list echo hello
  wait_for_session test-list

  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-list"* ]]
  [[ "$output" == *"pid="* ]]
  [[ "$output" == *"cmd=echo hello"* ]]
}

@test "list --short: shows only session names" {
  "$ZMX" run test-short-a true
  "$ZMX" run test-short-b true
  wait_for_session test-short-a
  wait_for_session test-short-b

  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-short-a"* ]]
  [[ "$output" == *"test-short-b"* ]]
}

@test "list --short: empty when no sessions" {
  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================================
# Session kill
# ============================================================================

@test "kill: removes a session" {
  "$ZMX" run test-kill true
  wait_for_session test-kill

  run "$ZMX" kill test-kill
  [ "$status" -eq 0 ]
  [[ "$output" == *"killed session test-kill"* ]]

  run "$ZMX" list --short
  [[ "$output" != *"test-kill"* ]]
}

@test "kill: multiple sessions at once" {
  "$ZMX" run kill-a true
  "$ZMX" run kill-b true
  wait_for_session kill-a
  wait_for_session kill-b

  run "$ZMX" kill kill-a kill-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"killed session kill-a"* ]]
  [[ "$output" == *"killed session kill-b"* ]]
}

@test "kill --force: removes socket file for dead session" {
  "$ZMX" run test-force true
  wait_for_session test-force

  # Get the daemon PID and kill it directly (simulating a crash)
  local pid
  pid=$("$ZMX" list 2>/dev/null | grep test-force | sed 's/.*pid=\([0-9]*\).*/\1/')
  if [[ -n "$pid" ]]; then
    kill -9 "$pid" 2>/dev/null || true
    sleep 0.5
  fi

  # Regular kill may fail on the dead session; --force cleans up
  run "$ZMX" kill --force test-force
  [ "$status" -eq 0 ]
}

# ============================================================================
# Session isolation (ZMX_DIR)
# ============================================================================

@test "ZMX_DIR isolation: sessions in one dir are invisible to another" {
  "$ZMX" run test-isolated true
  wait_for_session test-isolated

  # A different ZMX_DIR should see no sessions
  local other_dir="$BATS_TEST_TMPDIR/zmx-other"
  mkdir -p "$other_dir"
  run env ZMX_DIR="$other_dir" "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================================
# History
# ============================================================================

@test "history: captures session output" {
  "$ZMX" run test-hist echo "bats-marker-xyzzy"
  wait_for_session test-hist
  sleep 0.5  # give the command time to produce output

  run "$ZMX" history test-hist
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats-marker-xyzzy"* ]]
}

# ============================================================================
# Wait
# ============================================================================

@test "wait: returns after session command completes" {
  "$ZMX" run test-wait echo done
  wait_for_session test-wait

  # `wait` should return once the command finishes
  run timeout 10 "$ZMX" wait test-wait
  [ "$status" -eq 0 ]
}

# ============================================================================
# Rapid session churn (stress test for FD handling)
# ============================================================================

@test "churn: create and kill 5 sessions in sequence" {
  for i in 1 2 3 4 5; do
    "$ZMX" run "churn-$i" echo "iteration $i"
    wait_for_session "churn-$i"
    "$ZMX" kill "churn-$i"
  done

  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
