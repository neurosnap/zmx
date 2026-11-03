#!/usr/bin/env bats
# Real daemon checks complement the parser and capability host unit tests.

load test_helper

@test "invalid capability names fail before attach or run creates a session" {
  for command in attach run; do
    for names in missing osc7501,osc7501 osc7 osc7501, ,osc7501; do
      run "$ZMX" "$command" --capabilities="$names" rejected
      [ "$status" -ne 0 ]
      [[ "$output" == *capability* || "$output" == *capabilities* ]]
      [ ! -S "$ZMX_DIR/rejected" ]
    done
  done
}

@test "missing and repeated capability flags fail before creating a session" {
  for command in attach run; do
    run "$ZMX" "$command" --capabilities
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a comma-separated list"* ]]
    run "$ZMX" "$command" --capabilities --help
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a comma-separated list"* ]]
    run "$ZMX" "$command" --capabilities= --capabilities=osc7501 rejected
    [ "$status" -ne 0 ]
    [[ "$output" == *"only be specified once"* ]]
    [ ! -S "$ZMX_DIR/rejected" ]
  done
}

@test "nested attach rejects a capability selection without switching sessions" {
  run env ZMX_SESSION=not-running "$ZMX" attach --capabilities=osc7501 rejected
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires attaching from outside a zmx session"* ]]
  [ ! -S "$ZMX_DIR/rejected" ]
}
