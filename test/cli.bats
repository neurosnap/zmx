#!/usr/bin/env bats
# CLI argument validation tests for zmx.
# See https://github.com/neurosnap/zmx/issues/178

load test_helper

# ============================================================================
# Invalid commands must exit non-zero
# ============================================================================

@test "unknown command exits non-zero" {
  run "$ZMX" foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "unknown command alias exits non-zero" {
  run "$ZMX" not-a-real-command
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "completions with invalid shell exits non-zero" {
  run "$ZMX" completions foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown shell"* ]]
}

@test "completions alias with invalid shell exits non-zero" {
  run "$ZMX" c foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown shell"* ]]
}

@test "completions with no argument exits non-zero" {
  run "$ZMX" completions
  [ "$status" -ne 0 ]
  [[ "$output" == *"shell argument"* ]]
}

# ============================================================================
# Valid commands still exit zero
# ============================================================================

@test "help exits zero" {
  run "$ZMX" help
  [ "$status" -eq 0 ]
}

@test "version exits zero" {
  run "$ZMX" version
  [ "$status" -eq 0 ]
}

@test "completions with valid shell exits zero" {
  run "$ZMX" completions bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"_zmx_completions"* ]]
}

@test "completions --help exits zero" {
  run "$ZMX" completions --help
  [ "$status" -eq 0 ]
}
