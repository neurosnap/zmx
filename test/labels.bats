#!/usr/bin/env bats
# Label tests for zmx.

load test_helper

# ============================================================================
# Label CRUD
# ============================================================================

@test "set/get: round-trips labels" {
  "$ZMX" run test-labels -d sleep 30
  wait_for_session test-labels

  run "$ZMX" set test-labels project=zmx env=dev
  [ "$status" -eq 0 ]

  run "$ZMX" get test-labels
  [ "$status" -eq 0 ]
  [[ "$output" == *"env=dev"* ]]
  [[ "$output" == *"project=zmx"* ]]
}

@test "set: updates existing label" {
  "$ZMX" run test-update -d sleep 30
  wait_for_session test-update

  run "$ZMX" set test-update status=busy
  [ "$status" -eq 0 ]
  run "$ZMX" set test-update status=done
  [ "$status" -eq 0 ]

  run "$ZMX" get test-update
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=done"* ]]
  [[ "$output" != *"status=busy"* ]]
}

@test "set: rejects reserved key 'name'" {
  "$ZMX" run test-reserved -d sleep 30
  wait_for_session test-reserved

  run "$ZMX" set test-reserved name=bad
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-only built-in field"* ]]
}

@test "set: rejects reserved key 'start_dir'" {
  "$ZMX" run test-reserved2 -d sleep 30
  wait_for_session test-reserved2

  run "$ZMX" set test-reserved2 start_dir=/tmp
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-only built-in field"* ]]
}

@test "set: rejects reserved key 'cmd'" {
  "$ZMX" run test-reserved3 -d sleep 30
  wait_for_session test-reserved3

  run "$ZMX" set test-reserved3 cmd=bad
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-only built-in field"* ]]
}

@test "set with empty value removes label" {
  "$ZMX" run test-unset -d sleep 30
  wait_for_session test-unset

  run "$ZMX" set test-unset a=1 b=2
  run "$ZMX" set test-unset a=

  run "$ZMX" get test-unset
  [ "$status" -eq 0 ]
  [[ "$output" != *"a=1"* ]]
  [[ "$output" == *"b=2"* ]]
}

@test "clear: removes all labels" {
  "$ZMX" run test-clear -d sleep 30
  wait_for_session test-clear

  run "$ZMX" set test-clear x=1 y=2
  run "$ZMX" clear test-clear

  run "$ZMX" get test-clear
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "get: no session prints error" {
  run "$ZMX" get nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "get: no args prints error" {
  run env -u ZMX_SESSION "$ZMX" get
  [[ "$output" == *"SessionNameRequired"* ]]
}
