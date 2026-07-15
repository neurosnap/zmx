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
  [[ "$output" == *"session name required"* ]]
}

# ============================================================================
# List with labels and --where
# ============================================================================

@test "list: shows labels in output" {
  "$ZMX" run test-show -d sleep 30
  wait_for_session test-show

  run "$ZMX" set test-show project=zmx

  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"project=zmx"* ]]
}

@test "list --where: exact match on label" {
  "$ZMX" run test-where1 -d sleep 30
  "$ZMX" run test-where2 -d sleep 30
  wait_for_session test-where1
  wait_for_session test-where2

  run "$ZMX" set test-where1 role=web
  run "$ZMX" set test-where2 role=api

  run "$ZMX" list --short --where role=web
  [ "$status" -eq 0 ]
  [[ "$output" == "test-where1" ]]
}

@test "list --where: prefix match with * suffix" {
  "$ZMX" run test-pfx1 -d sleep 30
  "$ZMX" run test-pfx2 -d sleep 30
  wait_for_session test-pfx1
  wait_for_session test-pfx2

  run "$ZMX" set test-pfx1 path=/Users/max/code/zmx
  run "$ZMX" set test-pfx2 path=/Users/max/code/jbang

  run "$ZMX" list --short --where 'path=/Users/max/code*'
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-pfx1"* ]]
  [[ "$output" == *"test-pfx2"* ]]
}

@test "list --where: exact match on builtin name" {
  "$ZMX" run test-builtin -d sleep 30
  wait_for_session test-builtin

  run "$ZMX" list --short --where name=test-builtin
  [ "$status" -eq 0 ]
  [[ "$output" == "test-builtin" ]]
}

@test "list --where: prefix match on builtin name" {
  "$ZMX" run test-bpfx -d sleep 30
  wait_for_session test-bpfx

  run "$ZMX" list --short --where 'name=test-b*'
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-bpfx"* ]]
}

# ============================================================================
# Label inheritance
# ============================================================================

@test "inherit: child session inherits parent labels by default" {
  "$ZMX" run test-parent -d sleep 30
  wait_for_session test-parent
  "$ZMX" set test-parent project=zmx env=dev

  # Create a child session from inside the parent's env
  ZMX_SESSION=test-parent "$ZMX" run test-child -d sleep 30
  wait_for_session test-child

  run "$ZMX" get test-child
  [ "$status" -eq 0 ]
  [[ "$output" == *"project=zmx"* ]]
  [[ "$output" == *"env=dev"* ]]
}

@test "inherit: ZMX_INHERIT_LABELS= disables inheritance" {
  "$ZMX" run test-parent2 -d sleep 30
  wait_for_session test-parent2
  "$ZMX" set test-parent2 project=zmx env=dev

  ZMX_SESSION=test-parent2 ZMX_INHERIT_LABELS= "$ZMX" run test-noinherit -d sleep 30
  wait_for_session test-noinherit

  run "$ZMX" get test-noinherit
  [ "$status" -eq 0 ]
  [[ "$output" != *"project=zmx"* ]]
  [[ "$output" != *"env=dev"* ]]
}


@test "inherit: ZMX_INHERIT_LABELS=key filters to allowlist" {
  "$ZMX" run test-parent3 -d sleep 30
  wait_for_session test-parent3
  "$ZMX" set test-parent3 project=zmx env=dev team=core

  ZMX_SESSION=test-parent3 ZMX_INHERIT_LABELS=project,team "$ZMX" run test-filtered -d sleep 30
  wait_for_session test-filtered

  run "$ZMX" get test-filtered
  [ "$status" -eq 0 ]
  [[ "$output" == *"project=zmx"* ]]
  [[ "$output" == *"team=core"* ]]
  [[ "$output" != *"env=dev"* ]]
}


@test "list --where: no match returns empty" {
  "$ZMX" run test-nomatch -d sleep 30
  wait_for_session test-nomatch

  run "$ZMX" list --short --where role=nonexistent
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
