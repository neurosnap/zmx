#!/usr/bin/env bats
# Tests for `zmx run --no-create`.

load test_helper

@test "run --no-create: missing session fails and is not created" {
  run timeout 10 "$ZMX" run test-nocreate-missing --no-create echo should-not-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]

  run "$ZMX" list --short
  [[ "$output" != *"test-nocreate-missing"* ]]
}

@test "run --no-create: detached also fails for a missing session" {
  run timeout 10 "$ZMX" run test-nocreate-detached -d --no-create echo should-not-run
  [ "$status" -ne 0 ]

  run "$ZMX" list --short
  [[ "$output" != *"test-nocreate-detached"* ]]
}

@test "run --no-create: existing session runs the command" {
  run timeout 10 "$ZMX" run test-nocreate-existing true
  [ "$status" -eq 0 ]

  run timeout 10 "$ZMX" run test-nocreate-existing --no-create echo nocreate-marker-xyz
  [ "$status" -eq 0 ]
  [[ "$output" == *"nocreate-marker-xyz"* ]]
}

@test "run --no-create: flag after the command belongs to the command" {
  run timeout 10 "$ZMX" run test-nocreate-argpos true
  [ "$status" -eq 0 ]

  run timeout 10 "$ZMX" run test-nocreate-argpos echo --no-create
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-create"* ]]
}
