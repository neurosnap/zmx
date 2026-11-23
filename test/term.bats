#!/usr/bin/env bats

load test_helper

check_term() {
  local expected="$1"
  shift
  "$@" "$ZMX" attach test-term /bin/sh -c \
    'printf "TERM=<%s>\n" "$TERM"; exec sleep 30' </dev/null >/dev/null
  wait_for_output test-term "TERM=<$expected>"
}

@test "attach: missing TERM defaults to xterm-256color" {
  check_term xterm-256color env -u TERM -u ZMX_SESSION
}

@test "attach: empty TERM defaults to xterm-256color" {
  check_term xterm-256color env -u ZMX_SESSION TERM=
}

@test "attach: dumb TERM defaults to xterm-256color" {
  check_term xterm-256color env -u ZMX_SESSION TERM=dumb
}

@test "attach: explicit TERM is preserved" {
  check_term xterm-ghostty env -u ZMX_SESSION TERM=xterm-ghostty
}
