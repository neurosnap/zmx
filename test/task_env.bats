#!/usr/bin/env bats
# ZMX_TASK marks `run` sessions so shell configs can tell a task session apart
# from an interactive `attach` and skip prompts and other interactive-only
# output. ZMX_SESSION cannot express that: it is set for both.
#
# Markers are built with printf so the expected string never appears in the
# command line itself: `zmx run` types the command into the PTY, which echoes
# it back, and a marker matching that echo would pass before the command ran.

load test_helper

@test "run: exports ZMX_TASK=1 in the task session" {
  run timeout 10 "$ZMX" run task-env-set -d bash -c 'printf "task=%s\n" "${ZMX_TASK-unset}"'
  [ "$status" -eq 0 ]

  wait_for_output task-env-set "task=1"
  run "$ZMX" history task-env-set
  [[ "$output" == *"task=1"* ]]
}

@test "run: ZMX_SESSION is still exported alongside ZMX_TASK" {
  run timeout 10 "$ZMX" run task-env-both -d bash -c 'printf "sesh=%s\n" "${ZMX_SESSION-unset}"'
  [ "$status" -eq 0 ]

  wait_for_output task-env-both "sesh=task-env-both"
  run "$ZMX" history task-env-both
  [[ "$output" == *"sesh=task-env-both"* ]]
}
