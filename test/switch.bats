#!/usr/bin/env bats
# Switching an attached client to another session (`zmx attach <other>` with
# ZMX_SESSION set). `zmx attach` needs a tty, so the client runs in a pty.

load test_helper

# switch_client <from> <to>: move the client attached to <from> over to <to>,
# returning once it has left <from> and arrived at <to>.
switch_client() {
  ZMX_SESSION="$1" "$ZMX" attach "$2"
  wait_for_clients "$1" 0
  wait_for_clients "$2" 1
}

@test "switch: existing target keeps its own labels" {
  "$ZMX" run test-sw-keep -d sleep 30
  wait_for_session test-sw-keep

  pty_attach 10 --labels role=scratch test-sw-src sleep 30 3>&- &
  wait_for_clients test-sw-src 1

  switch_client test-sw-src test-sw-keep

  run "$ZMX" get test-sw-keep
  [ "$status" -eq 0 ]
  [[ "$output" != *"role=scratch"* ]]

  run "$ZMX" get test-sw-src
  [ "$status" -eq 0 ]
  [[ "$output" == *"role=scratch"* ]]

  kill %1 2>/dev/null || true
}

@test "switch: new target gets neither the client's labels nor its command" {
  pty_attach 10 --labels role=scratch test-sw-src2 sleep 30 3>&- &
  wait_for_clients test-sw-src2 1

  switch_client test-sw-src2 test-sw-new

  run "$ZMX" list
  [ "$status" -eq 0 ]
  local line
  line=$(grep -F "name=test-sw-new"$'\t' <<<"$output")
  [[ "$line" != *"role=scratch"* ]]
  [[ "$line" != *"cmd=sleep 30"* ]]

  kill %1 2>/dev/null || true
}
