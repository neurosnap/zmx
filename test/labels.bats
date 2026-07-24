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
  [[ "$output" == *"SessionNameRequired"* ]]
}

# ============================================================================
# Daemon-side validation (IPC bypass)
# ============================================================================
# The CLI validates the label charset before sending, but the daemon socket
# accepts messages from any writer. A value carrying \t or \n printed raw into
# `zmx list` forges extra fields or whole extra rows for anything parsing
# that output. The daemon must enforce the charset itself.

@test "daemon rejects a raw-IPC label whose value carries separators" {
  command -v python3 >/dev/null || skip "python3 required to craft raw IPC"
  "$ZMX" run test-rawlbl -d sleep 30
  wait_for_session test-rawlbl
  "$ZMX" set test-rawlbl legit=ok   # a valid pair via the CLI, for contrast

  # Craft a LabelSet (tag 15) frame directly on the session socket: header is
  # packed {u8 tag, u32 len} sized 8, little-endian. Payload smuggles a tab
  # and a newline — a forged field and a forged whole row.
  run python3 - "$ZMX_DIR" <<'PY'
import socket, struct, sys, os
sock_dir = sys.argv[1]
path = os.path.join(sock_dir, "test-rawlbl")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
payload = b"evil=x\tclients=9\nname=forged\tpid=1\tclients=0\tcreated=1"
s.sendall(struct.pack("<BIxxx", 15, len(payload)) + payload)
s.settimeout(1.0)
try:
    s.recv(64)
except Exception:
    pass
s.close()
PY
  [ "$status" -eq 0 ]

  # Nothing forged: one row for the session, real client count, no evil key.
  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$(printf '%s\n' "$output" | grep -c 'name=test-rawlbl')" -eq 1 ]]
  [[ "$output" != *"name=forged"* ]]
  [[ "$output" != *"evil="* ]]
  # The valid CLI-set pair survives; the rejected one didn't wedge the daemon.
  run "$ZMX" get test-rawlbl
  [[ "$output" == *"legit=ok"* ]]
}
