#!/usr/bin/env bats
# Working directory tracking tests for zmx.
#
# zmx learns a session's cwd from the OSC 7 the shell emits, which arrives as a
# percent-encoded file://<host><path> URI. That URI is what `list` reports, so
# the host stays visible and you can tell an SSH session apart from a local one.
# These tests pin that output plus the thing it depends on: the URI is decoded
# for the chdir, so a new session lands in a directory whose name needed
# escaping.

load test_helper

# Emit an OSC 7 for $2 from inside session $1, as a shell integration would.
osc7_session() {
  local name="$1" path="$2" encoded
  # Percent-encode spaces, the character that actually broke the chdir. The %
  # is doubled because this goes through printf, which would otherwise read
  # "%20s" as a width specifier.
  encoded="${path// /%%20}"
  "$ZMX" run "$name" -d sh -c \
    "printf '\033]7;file://$(hostname)$encoded\007marker-$name\n'; sleep 30"
}

@test "list: reports the cwd in OSC 7 form, host included" {
  local dir="$BATS_TEST_TMPDIR/zmx spaced dir"
  mkdir -p "$dir"

  osc7_session test-cwd-uri "$dir"
  wait_for_session test-cwd-uri
  wait_for_output test-cwd-uri marker-test-cwd-uri
  wait_for_cwd test-cwd-uri "cwd=file://$(hostname)${dir// /%20}"

  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"cwd=file://$(hostname)${dir// /%20}"* ]]
}

@test "list: shows a remote cwd's host, so SSH is visible" {
  "$ZMX" run test-cwd-remote -d sh -c \
    "printf '\033]7;file://some-remote-box/home/me\007marker-remote\n'; sleep 30"
  wait_for_session test-cwd-remote
  wait_for_output test-cwd-remote marker-remote
  wait_for_cwd test-cwd-remote "cwd=file://some-remote-box/home/me"

  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"cwd=file://some-remote-box/home/me"* ]]
}

@test "list: reports an OSC 7 URI even when given a plain path" {
  # `zmx run` hands the daemon the client's cwd as a path, so this covers the
  # encode direction rather than the decode one.
  cd "$BATS_TEST_TMPDIR"
  "$ZMX" run test-cwd-encode -d sleep 30
  wait_for_session test-cwd-encode

  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"cwd=file://$(hostname)/"* ]]
}

@test "new session starts in a cwd whose name needed escaping" {
  local dir="$BATS_TEST_TMPDIR/zmx spaced dir"
  mkdir -p "$dir"

  cd "$dir"
  "$ZMX" run test-cwd-chdir -d sh -c 'pwd; sleep 30'
  wait_for_session test-cwd-chdir
  wait_for_output test-cwd-chdir "zmx spaced dir"

  # `pwd` inside the session is what the daemon actually chdir'd into. Compare
  # basenames because macOS resolves /tmp to /private/tmp.
  run "$ZMX" history test-cwd-chdir
  [ "$status" -eq 0 ]
  [[ "$output" == *"/zmx spaced dir"* ]]
}

@test "unchanged OSC 7 is not logged again after output or queries" {
  local name=test-cwd-unchanged uri=file://localhost/tmp
  "$ZMX" run "$name" -d sh -c \
    'printf "\033]7;file://localhost/tmp\007cwd-ready\n"; cat'
  wait_for_output "$name" cwd-ready
  wait_for_cwd "$name" "cwd=$uri"

  "$ZMX" send "$name" $'ordinary-output\n'
  wait_for_output "$name" ordinary-output
  printf '\033]7;%s\007repeated-cwd\n' "$uri" | "$ZMX" print "$name"
  wait_for_output "$name" repeated-cwd
  wait_for_cwd "$name" "cwd=$uri"

  [ "$(grep -Fc "set cwd=$uri path=/tmp" "$ZMX_DIR/logs/$name.log")" -eq 1 ]
}

@test "OSC 7 tracks changed directories and returning to a previous directory" {
  local name=test-cwd-changes uri
  "$ZMX" run "$name" -d cat
  wait_for_session "$name"

  for uri in file://localhost/tmp/a%20b file://some-remote-box/home/me file://localhost/tmp/a%20b; do
    printf '\033]7;%s\007' "$uri" | "$ZMX" print "$name"
    wait_for_cwd "$name" "cwd=$uri"
  done
}
