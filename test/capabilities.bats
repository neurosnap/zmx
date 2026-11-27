#!/usr/bin/env bats
# Real daemon checks complement the parser and capability host unit tests.

load test_helper

@test "invalid capability names fail before attach or run creates a session" {
  for command in attach run; do
    for names in missing example,example example, ,example; do
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
    run "$ZMX" "$command" --capabilities= --capabilities=example rejected
    [ "$status" -ne 0 ]
    [[ "$output" == *"only be specified once"* ]]
    [ ! -S "$ZMX_DIR/rejected" ]
  done
}
