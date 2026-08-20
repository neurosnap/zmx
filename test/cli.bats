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

@test "get with no argument outside session exits non-zero" {
  run env -u ZMX_SESSION "$ZMX" get
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "set with no argument outside session exits non-zero" {
  run env -u ZMX_SESSION "$ZMX" set
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "clear with no argument outside session exits non-zero" {
  run env -u ZMX_SESSION "$ZMX" clear
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "detach outside session exits non-zero" {
  run env -u ZMX_SESSION "$ZMX" detach
  [ "$status" -ne 0 ]
  [[ "$output" == *"not inside a zmx session"* ]]
}

@test "history with no argument outside session exits non-zero" {
  run env -u ZMX_SESSION "$ZMX" history
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "kill with no argument exits non-zero" {
  run "$ZMX" kill
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "wait with no argument exits non-zero" {
  run "$ZMX" wait
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "tail with no argument exits non-zero" {
  run "$ZMX" tail
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "send with no argument exits non-zero" {
  run "$ZMX" send
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "print with no argument exits non-zero" {
  run "$ZMX" print
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "attach with missing labels value exits non-zero" {
  run "$ZMX" attach --labels
  [ "$status" -ne 0 ]
  [[ "$output" == *"--labels requires"* ]]
}

@test "print-env with no argument outside session exits non-zero" {
  run env -u ZMX_SESSION "$ZMX" print-env
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "write with no argument exits non-zero" {
  run "$ZMX" write
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "write with missing file path exits non-zero" {
  run "$ZMX" write dummy_session
  [ "$status" -ne 0 ]
  [[ "$output" == *"file path required"* ]]
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

@test "print-env --help exits zero" {
  run "$ZMX" print-env --help
  [ "$status" -eq 0 ]
}


