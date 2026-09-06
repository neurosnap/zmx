"""Leadership claim: two clients at different sizes, driven over real PTYs.

Exercises the whole wire — client stdin -> util.ClaimFilter -> IPC Claim ->
Daemon.handleClaim -> setLeader -> size request -> TIOCSWINSZ — and asserts the
two properties the unit tests cannot reach from inside a single process:

  1. a second client attaching does NOT resize the pty (handleInit sets a
     leader only when there is none), so opening another view of a session is
     non-disruptive;
  2. a claim DOES resize it, without any keystroke reaching the program.

Python rather than pure bash because the test needs two PTYs at known,
different window sizes, which `bats` has no way to allocate.

Usage: claim_leader.py <zmx-binary> <zmx-dir>
"""

import fcntl
import os
import pty
import re
import signal
import struct
import subprocess
import sys
import termios
import time

CLAIM = b"\x1b_zmx;claim\x1b\\"
SESSION = "claim-leader-test"


def attach(zmx, env, cols, rows):
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(zmx, [zmx, "attach", SESSION, "/bin/sh"], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    return pid, fd


def drain(fd, secs):
    end = time.time() + secs
    out = b""
    os.set_blocking(fd, False)
    while time.time() < end:
        try:
            out += os.read(fd, 65536)
        except (BlockingIOError, OSError):
            time.sleep(0.05)
    return out


def pty_size(fd):
    """What the session's shell believes the size is, as (rows, cols)."""
    drain(fd, 0.4)
    os.write(fd, b"stty size\n")
    time.sleep(1.2)
    text = drain(fd, 1.2).decode(errors="replace")
    # Guard the digit run against ANSI parameters (CSI ... ; ... m).
    hits = re.findall(r"(?<![\d;])(\d{1,4}) (\d{1,4})(?![\d;])", text)
    if not hits:
        raise AssertionError(f"no `stty size` output found in:\n{text!r}")
    return tuple(int(n) for n in hits[-1])


def main():
    zmx, zmx_dir = sys.argv[1], sys.argv[2]
    env = {**os.environ, "ZMX_DIR": zmx_dir}
    pids = []
    try:
        a_pid, a = attach(zmx, env, cols=100, rows=30)
        pids.append(a_pid)
        time.sleep(2.5)
        assert pty_size(a) == (30, 100), "first client should size the pty"

        b_pid, b = attach(zmx, env, cols=40, rows=12)
        pids.append(b_pid)
        time.sleep(2.5)
        assert pty_size(a) == (30, 100), "a second client must not resize the pty"

        os.write(b, CLAIM)
        time.sleep(2.5)
        assert pty_size(b) == (12, 40), "a claim must hand the pty size over"
    finally:
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        subprocess.run(
            [zmx, "kill", SESSION, "--force"], env=env, capture_output=True
        )
    print("ok")


if __name__ == "__main__":
    main()
