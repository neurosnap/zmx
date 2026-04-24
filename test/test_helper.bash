# test_helper.bash — shared setup/teardown for zmx BATS tests

REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  # Build once per test suite (skips if already built)
  if [[ ! -x "$REPO_DIR/zig-out/bin/zmx" ]]; then
    cd "$REPO_DIR" && zig build
  fi
  ZMX="$REPO_DIR/zig-out/bin/zmx"

  # Isolate socket dir so tests don't interfere with real sessions or each other
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx-sockets"
  mkdir -p "$ZMX_DIR"
}

teardown() {
  # Kill any sessions created during this test
  if [[ -d "$ZMX_DIR" ]]; then
    local sessions
    sessions=$("$ZMX" list --short 2>/dev/null) || true
    if [[ -n "$sessions" ]]; then
      echo "$sessions" | xargs "$ZMX" kill --force 2>/dev/null || true
    fi
  fi
}

# Helper: wait for a session to appear in list (up to N seconds)
wait_for_session() {
  local name="$1" timeout="${2:-5}" i=0
  while (( i < timeout * 10 )); do
    if "$ZMX" list --short 2>/dev/null | grep -qx "$name"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for session '$name'" >&2
  return 1
}
