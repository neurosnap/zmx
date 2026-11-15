#!/usr/bin/env bats
# Switching an attached client to another session (`zmx attach <other>` with
# ZMX_SESSION set). `zmx attach` needs a tty, so the client runs in a pty.

load test_helper

# pty_attach <hold_seconds> <attach args...>: run `zmx attach <args...>` in a pty
# for hold_seconds, draining its output so the client never blocks on writes.
pty_attach() {
  local hold="$1"
  shift
  python3 - "$ZMX" "$hold" "$@" 3>&- <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

zmx, hold, args = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
env = {k: v for k, v in os.environ.items() if k != "ZMX_SESSION"}
env.update(SHELL="/bin/sh", TERM="xterm-256color")
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
proc = subprocess.Popen([zmx, "attach", *args], stdin=slave, stdout=slave, stderr=slave, env=env)
deadline = time.monotonic() + hold
while time.monotonic() < deadline and proc.poll() is None:
    if select.select([master], [], [], 0.05)[0]:
        try:
            os.read(master, 65536)
        except OSError:
            break
if proc.poll() is None:
    proc.kill()
    proc.wait(timeout=5)
PY
}

# switch_client <from> <to>: move the client attached to <from> over to <to>,
# returning once it has left <from> and arrived at <to>.
switch_client() {
  ZMX_SESSION="$1" "$ZMX" attach "$2"
  wait_for_clients "$1" 0
  wait_for_clients "$2" 1
}

@test "switch: existing target keeps its own labels" {
  "$ZMX" run test-sw-keep -d sleep 30
  wait_for_session test-sw-keep

  pty_attach 10 --labels role=scratch test-sw-src sleep 30 3>&- &
  wait_for_clients test-sw-src 1

  switch_client test-sw-src test-sw-keep

  run "$ZMX" get test-sw-keep
  [ "$status" -eq 0 ]
  [[ "$output" != *"role=scratch"* ]]

  run "$ZMX" get test-sw-src
  [ "$status" -eq 0 ]
  [[ "$output" == *"role=scratch"* ]]

  kill %1 2>/dev/null || true
}

@test "switch: new target gets neither the client's labels nor its command" {
  pty_attach 10 --labels role=scratch test-sw-src2 sleep 30 3>&- &
  wait_for_clients test-sw-src2 1

  switch_client test-sw-src2 test-sw-new

  run "$ZMX" list
  [ "$status" -eq 0 ]
  local line
  line=$(grep -F "name=test-sw-new"$'\t' <<<"$output")
  [[ "$line" != *"role=scratch"* ]]
  [[ "$line" != *"cmd=sleep 30"* ]]

  kill %1 2>/dev/null || true
}
