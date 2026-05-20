#!/usr/bin/env bats
# Tests for stdin piped to `zmx run` sessions.
#
# Verifies that `zmx run` sessions always use bash (not the user's $SHELL),
# so piping commands via stdin works without quoting issues regardless of
# the user's default shell.

load test_helper

# ============================================================================
# Session shell is always bash
# ============================================================================

@test "run: session uses bash regardless of SHELL env" {
  run timeout 10 env SHELL=/usr/bin/fish "$ZMX" run test-shell-check echo 'hello'
  [ "$status" -eq 0 ]

  sleep 0.3
  run "$ZMX" history test-shell-check
  # Task marker uses $? (bash syntax), not $status (fish syntax)
  [[ "$output" == *'ZMX_TASK_COMPLETED:'* ]]
  [[ "$output" == *'$?'* ]]
}

# ============================================================================
# Stdin piped to run
# ============================================================================

@test "run: stdin pipe executes command" {
  run bash -c 'printf "echo stdin-marker-abc123\n" | timeout 10 "$0" run test-stdin-basic' "$ZMX"
  [ "$status" -eq 0 ]

  sleep 0.3
  run "$ZMX" history test-stdin-basic
  [[ "$output" == *"stdin-marker-abc123"* ]]
}

@test "run: stdin with special characters passes through unmangled" {
  run bash -c 'printf "echo '\''hello \$USER \$(whoami) \\\"double\\\" ; # comment'\''\n" | timeout 10 "$0" run test-stdin-special' "$ZMX"
  [ "$status" -eq 0 ]

  sleep 0.3
  run "$ZMX" history test-stdin-special
  [[ "$output" == *'$USER'* ]]
  [[ "$output" == *'$(whoami)'* ]]
}

@test "run: multiline stdin script executes all lines" {
  local script
  script=$(printf 'echo line-one-aaa\necho line-two-bbb\necho line-three-ccc\n')
  run bash -c 'printf "%s" "$1" | timeout 10 "$0" run test-stdin-multi' "$ZMX" "$script"
  [ "$status" -eq 0 ]

  sleep 0.5
  run "$ZMX" history test-stdin-multi
  [[ "$output" == *"line-one-aaa"* ]]
  [[ "$output" == *"line-two-bbb"* ]]
  [[ "$output" == *"line-three-ccc"* ]]
}

@test "run: stdin with heredoc in script" {
  # Heredoc delimiter as the last line of stdin should work now that
  # the task marker is sent on its own line.
  local script
  script=$(printf "cat <<'EOF'\nThis has \"double\" and 'single' quotes\nand \$variables that should not expand\nEOF\n")
  run bash -c 'printf "%s" "$1" | timeout 10 "$0" run test-stdin-heredoc' "$ZMX" "$script"
  [ "$status" -eq 0 ]

  sleep 0.5
  run "$ZMX" history test-stdin-heredoc
  [[ "$output" == *'$variables that should not expand'* ]]
}

@test "run: args-only still works" {
  run timeout 10 env SHELL=/bin/bash "$ZMX" run test-args-only echo args-only-marker-999
  [ "$status" -eq 0 ]

  sleep 0.3
  run "$ZMX" history test-args-only
  [[ "$output" == *"args-only-marker-999"* ]]
}
