# zmosh (contributed)

Remote zmx sessions over encrypted UDP, bootstrapped through SSH. The gateway
uses the current zmx daemon; networking stays in this optional contribution.
See [source provenance and adaptations](UPSTREAM.md).

## Build and use

From the zmx repository root, with Zig 0.16:

```sh
zig build contrib-zmosh -Doptimize=ReleaseSafe --prefix ~/.local
```

Install the same build on both machines. The remote machine needs an SSH
server and an available UDP port in **60000–60999**, reachable from the client.
Normal SSH authentication and host-key verification apply.

```sh
zmosh attach user@server work
# Optional SSH port (does not change the UDP port range):
ZMOSH_SSH_PORT=2222 zmosh attach user@server work
```

The session is created if absent. Closing/detaching the remote client leaves
the session alive. Press **Ctrl-\\** to detach; `ZMX_NO_DETACH_KEY` disables
this shortcut. Local `zmx` commands can inspect, attach to, and kill the same
session. Session prefixes and socket directories follow normal zmx settings.
Session switching from inside an attached remote session is not supported.

`zmosh serve SESSION` is the SSH bootstrap entry point. Its output contains a
session key: do not log, publish, or run it through an untrusted channel.

## Recovery and limits

The client retains ordered input/output across short network interruptions and
accepts authenticated address changes. A lost packet stalls later bytes until
retransmission; this is not a claim of mosh-equivalent latency. A gateway restart
requires a fresh attachment and key.

The intended tested recovery envelope is a five-second interruption with no
more than 512 KiB output at 100 KiB/s and 8 KiB interactive input. Queues and
deadlines are finite: bootstrap/peer timeout is 15 seconds, reliable or stdout
progress timeout is 10 seconds, and termination drain is 5 seconds. Excessive
output or a blocked sink can end the connection with an error; reattach to the
surviving session. These are connection limits, not session expiration limits.

Each native snapshot payload is limited to 1 MiB. Larger frames fail explicitly
instead of being truncated. Local IPC framing, unsent data, stdout data and the
32-packet transport windows have separate bounded storage. The existing core
daemon has its own queues; the gateway disconnects after two seconds of paused
Unix reads rather than claim a hard bound on all daemon memory.

A transport ACK means data was retained by the receiving endpoint. It does not
guarantee shell execution, durability after process crashes, or that a saturated
PTY accepted arbitrary pastes. The current core PTY input queue has a 256 KiB
limit. Terminal/SSH errors restore the local terminal and report failure.

The SSH bootstrap currently discovers the server's IPv4 address from its
authenticated SSH connection. IPv6-only destinations and SSH jump-host UDP
routing are not supported. The address reported by the SSH server must be
directly reachable over UDP; server-side NAT that reports a private address
requires a directly reachable SSH endpoint. Matching contrib builds are required; no public
wire-compatibility guarantee is made for the upstream fork.

## Tests

```sh
zig build
zig build contrib-zmosh
zig build zmosh-screen-probe
zig build test-contrib-zmosh
zig build check-contrib-zmosh
docker build -t zmx-contrib-test .
docker build -t zmx-contrib-e2e -f contrib/zmosh/test/Dockerfile .
docker run --rm -v "$PWD:/app" zmx-contrib-e2e
docker run --rm -v "$PWD:/app" zmx-contrib-e2e bats --jobs 1 contrib/zmosh/test/remote.bats
```

Build the three test executables before running the container. Individual
scenarios can be selected with `python3 contrib/zmosh/test/remote_e2e.py
--scenario restoration` inside the image. The screen probe uses the pinned
Ghostty parser to compare live and restored screen, cursor, and scrollback. The
Linux integration harness creates temporary SSH keys, an isolated server and
sessions, and a UDP fault proxy. It changes no host SSH configuration or
firewall rules. macOS compile checks are distinct from runtime verification.

After the ordinary build has fetched dependencies, exercise the isolated
no-route UDP regression separately (the normal unit run skips this case):

```sh
docker run --rm --network none -e ZMOSH_TEST_NO_ROUTE=1 \
  -v "$PWD:/app" -v /tmp/zmx-contrib-zig-cache:/root/.cache/zig \
  zmx-contrib-test zig build test-contrib-zmosh
```

The repository's `zig-pkg` directory must already contain the fetched packages;
the cache mount reuses compiler artifacts without requiring network access.
