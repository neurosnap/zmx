#!/usr/bin/env bats

load test_helper

# Read the output sent to a reconnecting terminal through the real IPC path.
snapshot() {
  python3 - "$ZMX_DIR/$1" 3>&- <<'PY'
import socket, struct, sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(1)
    client.connect(sys.argv[1])
    size = struct.pack("<HHHH", 24, 80, 0, 0)
    client.sendall(struct.pack("<BBHI", 7, 1, 0, len(size)) + size)
    pending = bytearray()
    while True:
        try:
            data = client.recv(65536)
        except socket.timeout:
            break
        if not data:
            break
        pending.extend(data)
        while len(pending) >= 8:
            tag, version, reserved, length = struct.unpack_from("<BBHI", pending)
            if len(pending) < 8 + length:
                break
            if tag == 1:
                sys.stdout.buffer.write(pending[8:8 + length])
            del pending[:8 + length]
PY
}

@test "Program Status restores reports saved while detached and replaces cleared tasks" {
  local name=test-status
  "$ZMX" run "$name" -d cat
  printf '\033]7501;state=working\033\\\033]7501;state=blocked:id=child\033\\status-ready\n' | "$ZMX" print "$name"
  wait_for_output "$name" status-ready

  run snapshot "$name"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033]7501;state=clear\033\\\033]7501;state=working\033\\\033]7501;state=blocked:id=child\033\\'* ]]

  printf '\033]7501;state=clear:id=child\033\\\033]7501;state=idle\033\\status-updated\n' | "$ZMX" print "$name"
  wait_for_output "$name" status-updated
  run snapshot "$name"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033]7501;state=clear\033\\\033]7501;state=idle\033\\'* ]]
  [[ "$output" != *'state=blocked:id=child'* ]]
}

@test "Program Status answers a real program's support query while detached" {
  "$ZMX" run test-status-query -d bash -c '
    stty -echo -icanon
    printf "\033]7501;?\007"
    if IFS= read -r -s -t 3 -d $'"'"'\a'"'"' reply; then
      case "$reply" in
        *7501*) printf "status_%s\n" answered ;;
      esac
    fi
    exec cat
  '
  wait_for_output test-status-query status_answered
}
