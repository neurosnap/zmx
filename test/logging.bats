#!/usr/bin/env bats
# PTY input logging tests for zmx.
#
# The session log lives on disk for the lifetime of the session. Anything
# typed at a password prompt reaches the daemon as PTY input, so the hex dump
# has to stay off unless the operator asks for it.

load test_helper

# ZMX_DIR is isolated per test, and logs land in $ZMX_DIR/logs.
session_log() {
  echo "$ZMX_DIR/logs/$1.log"
}

# "hunter2" as the daemon would hex-dump it.
SECRET_HEX='68756e74657232'

@test "log-input: PTY input is not logged by default" {
  run "$ZMX" run log-default -d cat
  [ "$status" -eq 0 ]
  wait_for_session log-default

  "$ZMX" send log-default 'hunter2'
  # The PTY echoes what it received, so this also proves the daemon queued it.
  wait_for_output log-default hunter2

  local log
  log="$(session_log log-default)"
  [ -f "$log" ]
  run grep -F 'hunter2' "$log"
  [ "$status" -ne 0 ]
  run grep -Fi "$SECRET_HEX" "$log"
  [ "$status" -ne 0 ]
}

@test "log-input: ZMX_LOG_INPUT opts the session in" {
  ZMX_LOG_INPUT=1 run "$ZMX" run log-optin -d cat
  [ "$status" -eq 0 ]
  wait_for_session log-optin

  # The sending client does not set ZMX_LOG_INPUT: policy belongs to the
  # daemon that owns the session, fixed when the session was created.
  "$ZMX" send log-optin 'hunter2'
  wait_for_output log-optin hunter2

  run grep -Fi "$SECRET_HEX" "$(session_log log-optin)"
  [ "$status" -eq 0 ]
}
