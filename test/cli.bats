#!/usr/bin/env bats
# Behavioral tests for zmx CLI argument parsing (zig-clap integration)

load test_helper

# ============================================================================
# Top-level help
# ============================================================================

@test "no args: defaults to list" {
  run "$ZMX"
  [ "$status" -eq 0 ]
  # No sessions in our isolated dir, so expect "no sessions found"
  [[ "$output" == *"no sessions found"* ]]
}

@test "--help: shows usage" {
  run "$ZMX" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx"* ]]
  [[ "$output" == *"[a]ttach"* ]]
}

@test "-h: shows usage" {
  run "$ZMX" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx"* ]]
}

@test "help command: shows usage" {
  run "$ZMX" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx"* ]]
}

@test "h alias: shows usage" {
  run "$ZMX" h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx"* ]]
}

# ============================================================================
# Version
# ============================================================================

@test "--version: shows version info" {
  run "$ZMX" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"zmx"* ]]
  [[ "$output" == *"ghostty_vt"* ]]
}

@test "-v: shows version info" {
  run "$ZMX" -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"zmx"* ]]
}

@test "v alias: shows version info" {
  run "$ZMX" v
  [ "$status" -eq 0 ]
  [[ "$output" == *"zmx"* ]]
}

# ============================================================================
# Subcommand --help
# ============================================================================

@test "list --help: shows subcommand usage" {
  run "$ZMX" list --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx list"* ]]
  [[ "$output" == *"--short"* ]]
}

@test "kill --help: shows subcommand usage" {
  run "$ZMX" kill --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx kill"* ]]
}

@test "attach -h: shows subcommand usage" {
  run "$ZMX" attach -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx attach"* ]]
  [[ "$output" == *"command..."* ]]
}

@test "run --help: shows subcommand usage" {
  run "$ZMX" run --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx run"* ]]
}

@test "wait --help: shows subcommand usage" {
  run "$ZMX" wait --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx wait"* ]]
}

@test "history --help: shows subcommand usage" {
  run "$ZMX" history --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx history"* ]]
  [[ "$output" == *"--vt"* ]]
}

@test "completions --help: shows subcommand usage" {
  run "$ZMX" completions --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx completions"* ]]
}

@test "detach --help: shows subcommand usage" {
  run "$ZMX" detach --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx detach"* ]]
}

# ============================================================================
# Aliases
# ============================================================================

@test "l alias: works like list" {
  run "$ZMX" l
  [ "$status" -eq 0 ]
}

@test "l --short: alias with flag" {
  run "$ZMX" l --short
  [ "$status" -eq 0 ]
}

@test "k --help: alias with help" {
  run "$ZMX" k --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx kill"* ]]
}

@test "hi --help: alias with help" {
  run "$ZMX" hi --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx history"* ]]
}

@test "w --help: alias with help" {
  run "$ZMX" w --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zmx wait"* ]]
}

# ============================================================================
# Error handling
# ============================================================================

@test "unknown command: reports error and exits non-zero" {
  run "$ZMX" foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]]
  [[ "$output" == *"--help"* ]]
}

@test "unknown top-level flag: reports error and exits non-zero" {
  run "$ZMX" --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid argument"* ]]
}

@test "list with unknown flag: reports error and exits non-zero" {
  run "$ZMX" list --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid argument"* ]]
}

@test "kill --force --help: shows subcommand usage" {
  run "$ZMX" kill --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--force"* ]]
}

@test "kill with unknown flag: reports error and exits non-zero" {
  run "$ZMX" kill --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid argument"* ]]
}

@test "list with unexpected positional: reports error and exits non-zero" {
  run "$ZMX" list blah
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid argument"* ]]
}

@test "history --vt --html: mutually exclusive flags error" {
  run "$ZMX" history test --vt --html
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

# ============================================================================
# Completions output
# ============================================================================

@test "completions bash: outputs script" {
  run "$ZMX" completions bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"_zmx_completions"* ]]
  # wait should be in the commands list
  [[ "$output" == *"wait"* ]]
}

@test "completions zsh: outputs script" {
  run "$ZMX" completions zsh
  [ "$status" -eq 0 ]
  [[ "$output" == *"_zmx"* ]]
  [[ "$output" == *"wait"* ]]
}

@test "completions fish: outputs script" {
  run "$ZMX" completions fish
  [ "$status" -eq 0 ]
  [[ "$output" == *"complete -c zmx"* ]]
}

@test "completions with no shell: exits cleanly" {
  run "$ZMX" completions
  [ "$status" -eq 0 ]
}

# ============================================================================
# list behavior
# ============================================================================

@test "list --short: no sessions returns empty" {
  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
