#!/usr/bin/env bats
# Socket and directory permission tests for zmx.

load test_helper

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

@test "permissions: session socket is private regardless of umask" {
  umask 000
  run "$ZMX" run perm-default -d cat
  [ "$status" -eq 0 ]
  wait_for_session perm-default

  [ "$(mode_of "$ZMX_DIR/perm-default")" = "600" ]
}

@test "permissions: ZMX_DIR_MODE widens the socket for group sharing" {
  umask 022
  export ZMX_DIR_MODE=770
  # A fresh directory: mkdir does not restat or chmod an existing one.
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx-shared"

  run "$ZMX" run perm-shared -d cat
  [ "$status" -eq 0 ]
  wait_for_session perm-shared

  [ "$(mode_of "$ZMX_DIR/perm-shared")" = "660" ]
  [ "$(mode_of "$ZMX_DIR")" = "770" ]
}
