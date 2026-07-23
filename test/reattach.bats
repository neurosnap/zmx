#!/usr/bin/env bats
# Re-attach behavior. A rendering `zmx attach` needs a tty, so these tests
# stand in for one with a small python client that connects to the session
# socket, sends an .Init frame, and holds the connection open — enough for the
# daemon's leader/resize/query-answering paths.

load test_helper

# raw_attach <session> <rows> <cols> [hold_seconds]
# Connect, send .Init (tag 7) with the given size, stay connected for HOLD
# seconds, then disconnect. Callers background it. fd 3 is closed so a
# backgrounded client can't hold bats' output pipe open.
raw_attach() {
  local session="$1" rows="$2" cols="$3" hold="${4:-1}"
  python3 - "$ZMX_DIR" "$session" "$rows" "$cols" "$hold" 3>&- <<'PY'
import os, socket, struct, sys, time
sock_dir, name, rows, cols, hold = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(os.path.join(sock_dir, name))
payload = struct.pack("<HHHH", rows, cols, 0, 0)            # ipc.Resize
s.sendall(struct.pack("<BIxxx", 7, len(payload)) + payload)  # ipc.Header{ .tag = .Init }
time.sleep(hold)
s.close()
PY
}

# Shell snippet: send DA1 and report whether anything answered within N seconds.
da1_probe() {
  echo "printf '\033[c'; if IFS= read -r -s -t $1 -d c r; then echo PROBE:ANSWERED; else echo PROBE:TIMEOUT; fi"
}

@test "daemon answers DA1 while detached, including after a client has detached" {
  "$ZMX" run test-da -d bash -c "$(da1_probe 3)"
  wait_for_output test-da "PROBE:ANSWERED"

  # Attach and detach a rendering client, then probe again. Answering used to
  # stop for good after the first detach.
  raw_attach test-da 24 80 0.3 &
  wait
  "$ZMX" run test-da bash -c "$(da1_probe 3)"
  run bash -c "\"$ZMX\" history test-da | grep -c PROBE:ANSWERED"
  [ "$output" -ge 2 ]
}

@test "daemon does not answer DA1 while a rendering client is attached" {
  "$ZMX" run test-da2 -d sleep 30
  wait_for_session test-da2
  # With a client attached, its terminal is expected to answer; ours has none,
  # so the probe should time out rather than get a reply from the daemon.
  raw_attach test-da2 24 80 4 &
  sleep 0.3
  "$ZMX" run test-da2 bash -c "$(da1_probe 2)"
  wait_for_output test-da2 "PROBE:TIMEOUT"
  wait
}

@test "re-attach at the same size still delivers SIGWINCH" {
  "$ZMX" run test-winch -d bash -c 'n=0; trap "n=\$((n+1)); echo WINCH:\$n" WINCH; echo READY; while :; do sleep 0.2; done'
  wait_for_output test-winch "READY"

  # First attach establishes 24x80.
  raw_attach test-winch 24 80 0.3 &
  wait
  sleep 0.3
  before=$("$ZMX" history test-winch | grep -c 'WINCH:' || true)

  # A second client at the same size: the kernel alone would send nothing.
  raw_attach test-winch 24 80 0.3 &
  wait
  sleep 0.3
  after=$("$ZMX" history test-winch | grep -c 'WINCH:' || true)

  [ "$after" -gt "$before" ]
}
