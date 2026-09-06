#!/usr/bin/env bats
# Leadership tests: which attached client's window size drives the pty.
#
# zmx allows several clients per session but only one leader. `handleInput`
# already hands leadership to any client that sends real user input, which
# suits a human at a keyboard — but a GUI frontend showing one session in two
# panes needs to say "size the pty from this one" on a click, without the
# keystroke reaching the running program. That is the Claim message.
#
# The real work is in claim_leader.py: the test needs two PTYs at known,
# different window sizes, which bats cannot allocate on its own.

load test_helper

@test "claim: a second client is non-disruptive, a claim moves the pty" {
  command -v python3 >/dev/null || skip "python3 needed to allocate test PTYs"
  run python3 "$BATS_TEST_DIRNAME/claim_leader.py" "$ZMX" "$ZMX_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
