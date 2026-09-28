#!/usr/bin/env bats

setup() {
  cd "$BATS_TEST_DIRNAME/../../.."
}

@test "remote CLI rejects missing attach arguments" {
  run zig-out/bin/zmosh attach
  [ "$status" -ne 0 ]
}

@test "remote CLI rejects option-like hosts" {
  run zig-out/bin/zmosh attach -oProxyCommand=exit unsafe
  [ "$status" -ne 0 ]
}

@test "remote CLI rejects missing serve session" {
  run zig-out/bin/zmosh serve
  [ "$status" -ne 0 ]
}

@test "real SSH bootstrap creates, reuses and detaches a session" {
  run python3 contrib/zmosh/test/remote_e2e.py --scenario bootstrap
  [ "$status" -eq 0 ]
}
