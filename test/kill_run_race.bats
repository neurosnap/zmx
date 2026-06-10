#!/usr/bin/env bats
# Regression test for the `zmx kill X; zmx run X` race.
#
# Previously `zmx kill` returned immediately after sending the IPC .Kill,
# while the daemon's shutdown defer ran handleKill() -- SIGHUP, 500ms sleep,
# SIGKILL -- BEFORE closing/unlinking the listen socket. A `zmx run X`
# issued in that window would connect() into the kernel backlog of a
# socket the daemon would never accept() on again, then get RST'd
# (ConnectionResetByPeer) when the daemon finally closed the listen fd,
# exiting 1 with no output and no session created.

load test_helper

@test "kill then immediate run with same name succeeds" {
  for i in 1 2 3; do
    "$ZMX" run race-x -d echo first
    wait_for_session race-x

    "$ZMX" kill race-x

    # Immediately reuse the same session name. Must not land in the
    # dying daemon's listen backlog.
    run "$ZMX" run race-x -d echo second
    echo "iteration $i: status=$status output=$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"session \"race-x\" created"* ]]

    # New session must be live and serving requests.
    wait_for_session race-x
    run "$ZMX" history race-x
    [ "$status" -eq 0 ]

    "$ZMX" kill race-x
  done
}
