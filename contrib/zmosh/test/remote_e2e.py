#!/usr/bin/env python3
"""Real SSH/PTY integration; run inside test/Dockerfile as root.

Build: docker build -t zmx-contrib-e2e -f contrib/zmosh/test/Dockerfile .
Run: docker run --rm -v "$PWD:/app" zmx-contrib-e2e
No Python packages, host SSH configuration, or firewall changes are required.
Only disposable keys and sockets below a fresh temporary directory are used.
The SSH ForceCommand relays the real serve command, rewriting its public UDP
port through a deterministic datagram proxy. It never records bootstrap keys.
"""
import argparse
import errno
import fcntl
import json
import hashlib
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

ROOT = Path(__file__).resolve().parents[3]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=15, **kwargs)


class Proxy:
    """Opaque UDP relay: counters select faults, never ciphertext inspection."""
    def __init__(self):
        self.front = self.bound()
        self.back = self.bound()
        self.control = self.bound()
        self.target = None
        self.client = None
        self.block_until = 0
        self.end_drops = 0
        self.end_drop_count = 0
        self.last_down_forwarded = None
        self.faults = {}
        self.held = {}
        self.count = {"up": 0, "down": 0}
        self.events = []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    @staticmethod
    def bound():
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", 0))
        return sock

    def event(self, kind, **fields):
        self.events.append(dict(at=round(time.monotonic(), 3), kind=kind, **fields))

    def outage(self, seconds):
        self.block_until = time.monotonic() + seconds
        self.event("outage", seconds=seconds)

    def fault(self, direction, offset, action):
        index = self.count[direction] + offset
        self.faults[(direction, index)] = action
        self.event("schedule", direction=direction, packet=index, action=action)

    def roam(self):
        # Keep old socket alive until thread observes replacement.
        old = self.back
        self.back = self.bound()
        self.event("roam", port=self.back.getsockname()[1])
        time.sleep(.1)
        old.close()

    def loop(self):
        while not self.stop.is_set():
            try:
                ready, _, _ = select.select([self.front, self.back, self.control], [], [], .02)
                for sock in ready:
                    data, source = sock.recvfrom(65535)
                    if sock is self.control:
                        self.target = ("127.0.0.1", int(data))
                        self.event("gateway", port=self.target[1])
                        continue
                    direction = "up" if sock is self.front else "down"
                    if direction == "up":
                        self.client = source
                    endpoint = self.target if direction == "up" else self.client
                    outbound = self.back if direction == "up" else self.front
                    self.count[direction] += 1
                    if self.count[direction] == 1:
                        self.event("first_datagram", direction=direction)
                    if not endpoint or time.monotonic() < self.block_until:
                        continue
                    # Paired protocol: 24-byte authenticated envelope + 20-byte
                    # transport + 8-byte empty SessionEnd record. Heartbeat=44.
                    if direction == "down" and len(data) == 52 and self.end_drops:
                        self.end_drop_count += 1
                        if self.end_drops > 0:
                            self.end_drops -= 1
                        if self.end_drop_count <= 3:
                            self.event("drop_session_end", packet=self.count[direction])
                        continue
                    action = self.faults.pop((direction, self.count[direction]), None)
                    if action == "drop":
                        continue
                    if action == "reorder":
                        self.held[direction] = (data, time.monotonic() + .15)
                        continue
                    outbound.sendto(data, endpoint)
                    if direction == "down":
                        self.last_down_forwarded = time.monotonic()
                    if action == "duplicate":
                        outbound.sendto(data, endpoint)
                    if direction in self.held:
                        outbound.sendto(self.held.pop(direction)[0], endpoint)
                for direction, (data, deadline) in list(self.held.items()):
                    if time.monotonic() >= deadline:
                        outbound = self.back if direction == "up" else self.front
                        endpoint = self.target if direction == "up" else self.client
                        if endpoint:
                            outbound.sendto(data, endpoint)
                        del self.held[direction]
            except (OSError, ValueError):
                if self.stop.is_set():
                    break

    def close(self):
        self.stop.set()
        self.thread.join(1)
        for sock in (self.front, self.back, self.control):
            sock.close()


class Terminal:
    def __init__(self, argv, env, rows=24, cols=80):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.flags = fcntl.fcntl(self.slave, fcntl.F_GETFL)
        self.resize(rows, cols)
        self.proc = subprocess.Popen(argv, stdin=self.slave, stdout=self.slave,
                                     stderr=self.slave, env=env, start_new_session=True)
        self.data = bytearray()

    def resize(self, rows, cols):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        if hasattr(self, "proc"):
            self.proc.send_signal(signal.SIGWINCH)

    def pump(self, seconds=.05):
        if select.select([self.master], [], [], seconds)[0]:
            try:
                data = os.read(self.master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    return
                raise
            self.data.extend(data)
            # A minimal terminal response for a shell querying primary DA.
            if b"\x1b[c" in data or b"\x1b[0c" in data:
                self.send(b"\x1b[?1;2c")

    def send(self, data):
        os.write(self.master, data)

    def command(self, command):
        self.send(command.encode() + b"\r")

    def expect(self, token, seconds=10, start=0):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pump()
            if token in self.data[start:]:
                return
            require(self.proc.poll() is None, f"client exited {self.proc.returncode} before expected output")
        raise AssertionError(f"expected output absent after {seconds}s ({len(self.data)} bytes received)")

    def exit(self, seconds=8, success=True):
        deadline = time.monotonic() + seconds
        while self.proc.poll() is None and time.monotonic() < deadline:
            self.pump()
        require(self.proc.poll() is not None, "client exceeded shutdown deadline")
        self.pump(0)
        if success:
            require(self.proc.returncode == 0, f"client exited {self.proc.returncode}")
        require(termios.tcgetattr(self.slave) == self.original, "client did not restore termios")
        require(fcntl.fcntl(self.slave, fcntl.F_GETFL) == self.flags,
                "client did not restore descriptor flags")

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        os.close(self.master)
        os.close(self.slave)


class Fixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zmosh-e2e-")
        self.path = Path(self.temp.name)
        self.proxy = Proxy()
        self.clients = []
        self.sshd = None
        self.env = dict(os.environ, ZMX_DIR=str(self.path / "sessions"), TERM="xterm-256color",
                        SHELL="/bin/bash")
        (self.path / "sessions").mkdir()
        self.bin = self.path / "bin"
        self.bin.mkdir()
        (self.bin / "zmosh").symlink_to(ROOT / "zig-out/bin/zmosh")
        self.env["PATH"] = str(self.bin) + ":" + os.environ["PATH"]

    def start(self):
        require(os.geteuid() == 0, "isolated sshd fixture requires root; use test/Dockerfile")
        sshd = shutil.which("sshd") or "/usr/sbin/sshd"
        require(Path(sshd).exists(), "sshd unavailable; build contrib/zmosh/test/Dockerfile")
        for binary in ("zmx", "zmosh"):
            require((ROOT / "zig-out/bin" / binary).is_file(), f"build {binary} before E2E")
        for name in ("host", "client"):
            run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.path/name)])
        (self.path / "authorized_keys").write_text((self.path / "client.pub").read_text())
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        listener.close()
        self.env["ZMOSH_SSH_PORT"] = str(port)
        hostkey = (self.path / "host.pub").read_text().split()
        (self.path / "known_hosts").write_text(f"[127.0.0.1]:{port} {hostkey[0]} {hostkey[1]}\n")
        config = self.path / "ssh_config"
        config.write_text(f"""Host *
  HostName 127.0.0.1
  Port {port}
  User root
  IdentityFile {self.path}/client
  IdentitiesOnly yes
  UserKnownHostsFile {self.path}/known_hosts
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  BatchMode yes
  LogLevel ERROR
""")
        # A real ssh executable with isolated options, not a fake SSH transport.
        ssh = self.bin / "ssh"
        ssh.write_text("#!/bin/sh\nexec /usr/bin/ssh -F " + shlex.quote(str(config)) + ' "$@"\n')
        ssh.chmod(0o755)
        relay = self.path / "relay.py"
        relay.write_text("""#!/usr/bin/env python3
import os, socket, subprocess, sys
p = subprocess.Popen(['/bin/sh', '-c', os.environ['SSH_ORIGINAL_COMMAND']], stdout=subprocess.PIPE)
for line in p.stdout:
    if line.startswith(b'ZMX_CONNECT udp '):
        parts = line.split()
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.sendto(parts[2], ('127.0.0.1', CONTROL))
        s.close()
        parts[2] = str(PROXY).encode()
        line = b' '.join(parts) + b'\\n'
    sys.stdout.buffer.write(line)
    sys.stdout.buffer.flush()
sys.exit(p.wait())
""".replace("CONTROL", str(self.proxy.control.getsockname()[1]))
            .replace("PROXY", str(self.proxy.front.getsockname()[1])))
        relay.chmod(0o755)
        # ForceCommand's environment is private to this disposable server.
        force = self.path / "force"
        force.write_text("#!/bin/sh\n" + "\n".join(
            f"export {key}={shlex.quote(self.env[key])}" for key in ("PATH", "ZMX_DIR", "SHELL"))
            + "\nexec /usr/bin/python3 " + shlex.quote(str(relay)) + "\n")
        force.chmod(0o755)
        server = self.path / "sshd_config"
        server.write_text(f"""ListenAddress 127.0.0.1
Port {port}
HostKey {self.path}/host
PidFile {self.path}/sshd.pid
AuthorizedKeysFile {self.path}/authorized_keys
StrictModes no
PermitRootLogin yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
ForceCommand {force}
LogLevel ERROR
""")
        self.sshd = subprocess.Popen([sshd, "-D", "-e", "-f", str(server)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), .1):
                    return
            except OSError:
                require(self.sshd.poll() is None, "isolated sshd failed to start")
                time.sleep(.03)
        raise AssertionError("isolated sshd readiness timeout")

    def attach(self, name="e2e", rows=24, cols=80, local=False):
        argv = [str(ROOT / "zig-out/bin" / ("zmx" if local else "zmosh")), "attach"]
        if not local:
            argv.append("127.0.0.1")
        client = Terminal(argv + [name], self.env, rows, cols)
        self.clients.append(client)
        return client

    def core(self, *args):
        return run([str(ROOT / "zig-out/bin/zmx"), *args], env=self.env).stdout

    def owned_pids(self):
        marker = ("ZMX_DIR=" + self.env["ZMX_DIR"]).encode()
        found = []
        for entry in Path('/proc').iterdir():
            if entry.name.isdecimal():
                try:
                    if marker in (entry / 'environ').read_bytes().split(b'\0'):
                        found.append(int(entry.name))
                except (OSError, PermissionError):
                    pass
        return found

    def daemon_pid(self, name="e2e"):
        path = self.env["ZMX_DIR"] + "/" + name
        inodes = {line.split()[6] for line in Path('/proc/net/unix').read_text().splitlines()[1:]
                  if line.split()[-1] == path}
        for pid in self.owned_pids():
            try:
                if any(os.readlink(fd) in {f"socket:[{i}]" for i in inodes}
                       for fd in Path(f'/proc/{pid}/fd').iterdir()):
                    return pid
            except OSError:
                pass
        raise AssertionError("daemon socket owner not found")

    def ready(self, client, suffix="READY"):
        deadline = time.monotonic() + 15
        while termios.tcgetattr(client.slave)[3] & termios.ICANON:
            client.pump()
            require(client.proc.poll() is None, "client exited before terminal initialization")
            require(time.monotonic() < deadline, "terminal initialization deadline")
        client.command(f"stty -echo; printf 'E2E_%s\\n' '{suffix}'")
        client.expect(("E2E_" + suffix).encode())
        children = Path(f"/proc/{client.proc.pid}/task/{client.proc.pid}/children").read_text().split()
        for pid in children:
            try:
                command = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
                require(not command or b"ssh" not in Path(os.fsdecode(command[0])).name.encode(),
                        "SSH bootstrap child remains after interactive readiness")
            except FileNotFoundError:
                pass

    def detach(self, client):
        client.send(b"\x1c")
        client.exit()
        require(b"e2e" in self.core("list", "--short"), "detach destroyed daemon")
        deadline = time.monotonic() + 6
        while True:
            workers = []
            for pid in self.owned_pids():
                try:
                    if b"--gateway" in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0"):
                        workers.append(pid)
                except FileNotFoundError:
                    pass
            if not workers:
                break
            require(time.monotonic() < deadline, "gateway leaked after detach")
            time.sleep(.05)

    def close(self):
        for client in self.clients:
            client.close()
        try:
            names = self.core("list", "--short").decode().splitlines()
            if names:
                self.core("kill", "--force", *names)
        except (subprocess.SubprocessError, OSError):
            pass
        # Match only our unique ZMX_DIR. Never kill processes by global name.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for pid in self.owned_pids():
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
            time.sleep(.1)
        if self.sshd:
            self.sshd.terminate()
            self.sshd.wait(timeout=3)
            self.sshd.stderr.close()
        self.proxy.close()
        self.temp.cleanup()


def bootstrap(f):
    first = f.attach()
    f.ready(first)
    pid = f.daemon_pid()
    f.detach(first)
    second = f.attach()
    f.ready(second, "REATTACHED")
    require(f.daemon_pid() == pid, "existing session was recreated")
    f.detach(second)


def first_attach(f):
    startup = f.path / "startup-shell"
    timestamp = f.path / "startup-time"
    code = ("import os,time; " +
            "open(" + repr(str(timestamp)) + ", 'w').write(str(time.monotonic())); " +
            "os.write(1,b'PRE_INIT_OUTPUT\\n')")
    startup.write_text("#!/bin/sh\npython3 -c " + shlex.quote(code) +
                       "\nexec /bin/bash --noprofile --norc -i\n")
    startup.chmod(0o755)
    force = f.path / "force"
    force.write_text(force.read_text().replace("export SHELL=/bin/bash",
                                               "export SHELL=" + shlex.quote(str(startup))))
    f.proxy.outage(1)
    client = f.attach()
    deadline = time.monotonic() + .8
    while not timestamp.exists() and time.monotonic() < deadline:
        time.sleep(.01)
    require(timestamp.exists(), "startup output was not produced before Init gate")
    history = f.core("history", "e2e")
    require(b"PRE_INIT_OUTPUT" in history, "daemon did not process pre-Init startup output")
    require(time.monotonic() < f.proxy.block_until, "Init gate expired before startup observation")
    client.expect(b"PRE_INIT_OUTPUT", seconds=10)
    first_up = next(event["at"] for event in f.proxy.events
                    if event["kind"] == "first_datagram" and event["direction"] == "up")
    require(float(timestamp.read_text()) < first_up,
            "startup fixture did not emit before first remote Init")
    f.ready(client, "AFTER_INIT")
    f.detach(client)


def preinit_noisy(f):
    local = f.attach(local=True)
    f.ready(local, "LOCAL_BEFORE_INIT")
    pid = f.daemon_pid()
    f.proxy.outage(4)
    remote = f.attach()
    deadline = time.monotonic() + 2
    while f.proxy.target is None:
        remote.pump()
        require(time.monotonic() < deadline, "gateway bootstrap readiness deadline")
    workers = []
    for process in f.owned_pids():
        try:
            if b"--gateway" in Path(f"/proc/{process}/cmdline").read_bytes().split(b"\0"):
                workers.append(process)
        except FileNotFoundError:
            pass
    require(len(workers) == 1, "expected one waiting gateway")
    code = ("import os,time; "
            "[(os.write(1,b'\\x1bPz'+b'n'*524288+b'\\x1b\\\\'),time.sleep(.05)) for _ in range(40)]; "
            "print('PREINIT_NOISE_DONE',flush=True)")
    local.command("python3 -c " + shlex.quote(code))
    peak = 0
    checked = 0
    deadline = time.monotonic() + 2.5
    while time.monotonic() < deadline:
        local.pump(.01)
        inodes = {line.split()[6] for line in Path('/proc/net/unix').read_text().splitlines()[1:]}
        for fd in Path(f"/proc/{workers[0]}/fd").iterdir():
            try:
                require(os.readlink(fd) not in {f"socket:[{i}]" for i in inodes},
                        "unauthenticated gateway retained a native Unix connection")
            except FileNotFoundError:
                pass
        status = Path(f"/proc/{pid}/status").read_text().splitlines()
        peak = max(peak, next(int(line.split()[1]) for line in status if line.startswith("VmRSS:")))
        checked += 1
    require(time.monotonic() < f.proxy.block_until, "pre-Init observation outlived UDP gate")
    local.expect(b"PREINIT_NOISE_DONE", seconds=5)
    f.ready(remote, "AFTER_NOISY_INIT")
    require(f.daemon_pid() == pid, "first UDP outage recreated existing daemon")
    f.proxy.event("preinit_noisy", native_socket_checks=checked, peak_daemon_kib=peak,
                  offered_bytes=20*1024*1024)
    f.detach(remote)


def recovery(f):
    client = f.attach()
    f.ready(client)
    pid = f.daemon_pid()
    # A raw PTY reader receives exactly 8KiB while a concurrent producer emits
    # 512KiB at100KiB/s. Hash+byte count detect reordering, loss and duplication.
    code = "\n".join([
        "import os,time,tty,termios,threading,hashlib",
        "old=termios.tcgetattr(0); tty.setraw(0)",
        "def produce():",
        " time.sleep(.2)",
        " for _ in range(64): os.write(1,b'R'*8192); time.sleep(.08)",
        "print('RECOVERY_'+'READY',flush=True)",
        "worker=threading.Thread(target=produce); worker.start(); data=bytearray()",
        "while len(data)<8192: data.extend(os.read(0,8192-len(data)))",
        "print('INPUT_'+'SHA:'+hashlib.sha256(data).hexdigest(),flush=True)",
        "worker.join(); termios.tcsetattr(0,termios.TCSANOW,old)",
        "print('OUTAGE_'+'DONE',flush=True)",
    ])
    client.command("python3 -c " + shlex.quote(code))
    client.expect(b"RECOVERY_READY")
    initial_r = client.data.count(b"R")
    start = len(client.data)
    f.proxy.outage(5)
    payload = (b"0123456789abcdefghijklmnopqrstuvwxyz" * 228)[:8192]
    require(len(payload) == 8192, "interactive input fixture size changed")
    client.send(payload)
    client.resize(31, 91)
    client.expect(b"OUTAGE_DONE", seconds=13, start=start)
    checksum = b"INPUT_SHA:" + hashlib.sha256(payload).hexdigest().encode()
    client.expect(checksum, seconds=5, start=start)
    require(client.data[start:].count(checksum) == 1, "input replayed after interruption")
    require(client.data.count(b"R") - initial_r == 524288, "interruption lost or duplicated producer bytes")
    require(f.daemon_pid() == pid, "interruption recreated daemon")
    client.command("stty size; printf 'RESIZE_%s\\n' DONE")
    client.expect(b"31 91", start=start)
    f.proxy.event("recovery_bytes", output=524288, input=8192)
    f.detach(client)


def packets(f):
    client = f.attach()
    f.ready(client)
    for direction in ("up", "down"):
        f.proxy.fault(direction, 1, "drop")
        f.proxy.fault(direction, 3, "reorder")
        f.proxy.fault(direction, 5, "duplicate")
    start = len(client.data)
    client.command("python3 -c \"import os; os.write(1,bytes([226,130,172])+b'\\\\x1b[31m'+b'P'*100000+b'PACKETS_DONE\\\\n')\"")
    client.expect(b"PACKETS_DONE", seconds=12, start=start)
    require(client.data[start:].count(b"P") == 100001, "loss, duplicate or corruption in packet workload")
    require(b"\xe2\x82\xac\x1b[31m" in client.data[start:], "UTF-8/escape bytes changed")
    f.detach(client)


def roaming(f):
    client = f.attach()
    f.ready(client)
    pid = f.daemon_pid()
    f.proxy.roam()
    # Invalid new-source datagrams must not steal the established peer.
    attacker = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    attacker.sendto(b"forged" * 20, f.proxy.target)
    attacker.close()
    start = len(client.data)
    client.command("printf 'ROAM_%s\\n' OK")
    client.expect(b"ROAM_OK", start=start)
    require(f.daemon_pid() == pid, "roaming recreated daemon")
    f.detach(client)


def resize(f):
    remote = f.attach(rows=25, cols=85)
    f.ready(remote)
    remote.command("stty size")
    remote.expect(b"25 85")
    local = f.attach(local=True, rows=33, cols=99)
    f.ready(local, "LOCAL")
    local.command("stty size")
    local.expect(b"33 99")
    start = len(remote.data)
    remote.command("stty size")
    remote.expect(b"25 85", start=start)
    f.detach(remote)


def final_output(f):
    client = f.attach()
    f.ready(client)
    start = len(client.data)
    client.command("python3 -c \"import os; os.write(1,b'F'*307200+b'FINAL_MARKER\\\\n')\"; exit")
    client.expect(b"FINAL_MARKER", seconds=12, start=start)
    client.exit()
    require(client.data[start:].count(b"F") == 307201, "final output was lost or duplicated")


def screen(f, client, label):
    probe = ROOT / "zig-out/bin/zmosh-screen-probe"
    require(probe.is_file(), "build zmosh-screen-probe before restoration E2E")
    capture = f.path / (label + ".vt")
    capture.write_bytes(client.data)
    return json.loads(run([str(probe), str(capture), "80", "24"]).stdout)


def settle(client, seconds=.3):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        client.pump(.02)


def restoration(f):
    first = f.attach()
    f.ready(first)
    # 390 KiB of distinguishable history, then a nontrivial visible screen.
    code = ("import os,time; os.write(1,b'\\x1b[2J\\x1b[H\\x1b[3J'); "
            "os.write(1,b''.join((('%05d '%i)+'h'*71+'\\n').encode() for i in range(5000))); "
            "os.write(1,b'\\r\\n'*24+b'\\x1b[2J\\x1b[3;7H\\x1b[31mRESTORED_SCREEN\\x1b[0m\\x1b[8;11H'); "
            "time.sleep(30)")
    first.command("python3 -c " + shlex.quote(code))
    first.expect(b"RESTORED_SCREEN", seconds=12)
    settle(first)
    expected = screen(f, first, "live")
    numbered = [line for line in expected["scrollback_text"].splitlines()
                if len(line) == 77 and line[:5].isdigit()]
    require(numbered == [f"{index:05d} " + "h"*71 for index in range(5000)],
            "live restoration fixture did not retain all 5000 ordered rows")
    f.detach(first)
    second = f.attach()
    # Interrupt an actual large snapshot after bytes have begun arriving.
    deadline = time.monotonic() + 10
    while len(second.data) < 16384:
        second.pump()
        require(second.proc.poll() is None, "reattach ended during restoration")
        require(time.monotonic() < deadline, "large snapshot did not begin")
    f.proxy.outage(.7)
    second.expect(b"RESTORED_SCREEN", seconds=12)
    settle(second)
    require(len(second.data) >= 300 * 1024, "restoration fixture did not exercise a 300KiB snapshot")
    actual = screen(f, second, "restored")
    for key in ("text", "cursor_x", "cursor_y", "alternate", "scrollback_text"):
        if key in expected:
            require(actual.get(key) == expected[key], "restored Ghostty " + key + " differs")
    f.proxy.event("snapshot", bytes=len(second.data), oracle="pinned Ghostty", rows=5000)
    f.core("print", "e2e", "\x1b[?1049h\x1b[2J\x1b[4;5HALTERNATE_MARKER\x1b[7;9H")
    second.expect(b"ALTERNATE_MARKER")
    settle(second)
    alternate = screen(f, second, "alternate-live")
    require(alternate["alternate"], "alternate-screen fixture did not enter alternate buffer")
    f.detach(second)
    third = f.attach()
    third.expect(b"ALTERNATE_MARKER")
    settle(third)
    restored_alternate = screen(f, third, "alternate-restored")
    require(restored_alternate == alternate, "alternate screen state did not restore")
    f.detach(third)


def overload(f):
    client = f.attach()
    f.ready(client)
    pid = f.daemon_pid()
    def rss():
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
        raise AssertionError("daemon RSS unavailable")
    gateway_pids = [pid for pid in f.owned_pids()
                    if b"--gateway" in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")]
    require(len(gateway_pids) == 1, "overload fixture expected one gateway")
    gateway_pid = gateway_pids[0]
    def native_connected():
        unix_inodes = {line.split()[6] for line in Path('/proc/net/unix').read_text().splitlines()[1:]}
        try:
            return any(os.readlink(fd) in {f"socket:[{inode}]" for inode in unix_inodes}
                       for fd in Path(f"/proc/{gateway_pid}/fd").iterdir())
        except FileNotFoundError:
            return False
    require(native_connected(), "gateway native socket missing before overload")
    baseline = rss()
    peak = baseline
    # Offer 10 MiB/s for exactly 2s; count accepted PTY bytes separately.
    stats = f.path / "producer-stats.json"
    code = "\n".join([
        "import os,time,fcntl,json",
        "print('OVERLOAD_BEGIN',flush=True); time.sleep(.2)",
        "os.write(1,bytes([27,80,122]))",
        "flags=fcntl.fcntl(1,fcntl.F_GETFL); os.set_blocking(1,False)",
        "start=time.monotonic(); sent=0; blocked=0; data=b'O'*65536",
        "while time.monotonic()-start < 2:",
        " target=min(20*1024*1024,int((time.monotonic()-start)*10*1024*1024))",
        " if sent>=target: time.sleep(.001); continue",
        " try: sent+=os.write(1,data[:min(len(data),target-sent)])",
        " except BlockingIOError: blocked+=1; time.sleep(.001)",
        "fcntl.fcntl(1,fcntl.F_SETFL,flags)",
        "open("+repr(str(stats))+",'w').write(json.dumps(dict(admitted_bytes=sent,blocked_writes=blocked,seconds=time.monotonic()-start)))",
        "os.write(1,bytes([27,92])); print('OVERLOAD_END',flush=True)",
    ])
    client.command("python3 -c " + shlex.quote(code))
    client.expect(b"OVERLOAD_BEGIN")
    f.proxy.outage(8)
    started = time.monotonic()
    disconnected_at = None
    while time.monotonic() - started < 4:
        peak = max(peak, rss())
        if disconnected_at is None and not native_connected():
            disconnected_at = time.monotonic() - started
        time.sleep(.02)
    f.proxy.event("daemon_memory_sample", baseline_kib=baseline, peak_kib=peak,
                  four_second_kib=rss(), native_disconnect_seconds=disconnected_at, producer_end=b"OVERLOAD_END" in f.core("history", "e2e"),
                  producer=json.loads(stats.read_text()) if stats.exists() else None)
    require(disconnected_at is not None and disconnected_at < 3,
            "gateway did not close native socket within read-pause deadline plus startup grace")
    # Local IPC and a new native terminal must remain usable after read pause.
    require(b"e2e" in f.core("list", "--short"), "overload destroyed daemon")
    local = f.attach(local=True)
    f.ready(local, "OVERLOAD_LOCAL")
    require(f.daemon_pid() == pid, "overload recreated daemon")
    client.exit(seconds=17, success=False)
    require(client.proc.returncode != 0, "sustained overload silently succeeded")
    f.proxy.event("daemon_memory", baseline_kib=baseline, peak_kib=peak,
                  after_disconnect_kib=rss(), offered_bytes=20*1024*1024,
                  admitted_bytes=json.loads(stats.read_text())["admitted_bytes"])


def native_boundaries(f):
    # Real SSH/client/gateway, with a controlled native daemon socket. This
    # tests exact frame boundaries independently of Ghostty serialization size.
    marker = b"NATIVE_FRAME_END"
    payload = b"Q" * (1024 * 1024 - len(marker)) + marker
    cases = {
        "cap": (struct.pack("<BIxxx", 1, len(payload)) + payload, True),
        "blocked_end": (struct.pack("<BIxxx", 1, len(payload)) + payload, False),
        "overcap": (struct.pack("<BIxxx", 1, len(payload) + 1), False),
        "partial_header": (b"\x01\x10", False),
        "partial_payload": (struct.pack("<BIxxx", 1, 100) + b"partial", False),
    }
    for name, (frame, success) in cases.items():
        path = Path(f.env["ZMX_DIR"]) / name
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        listener.listen(4)
        listener.settimeout(.1)
        stop = threading.Event()
        errors = []
        def serve():
            primed = False
            try:
                while not stop.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(15)
                        buffered = bytearray()
                        while not stop.is_set():
                            chunk = connection.recv(4096)
                            if not chunk:
                                break  # ensureSession's existence probe.
                            buffered.extend(chunk)
                            detached = False
                            while len(buffered) >= 8:
                                tag, size = struct.unpack("<BIxxx", buffered[:8])
                                if len(buffered) < 8 + size:
                                    break
                                del buffered[:8 + size]
                                if tag == 3:
                                    primed = True
                                    detached = True
                                    break
                                if tag == 7 and primed:
                                    connection.sendall(frame)
                                    connection.shutdown(socket.SHUT_WR)
                                    return
                                require(tag in (7, 2), "unexpected native priming record")
                            if detached:
                                break
            except Exception as exc:
                if not stop.is_set():
                    errors.append(type(exc).__name__)
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try:
            client = f.attach(name=name)
            if success:
                client.expect(marker, seconds=20)
            if name == "blocked_end":
                deadline = time.monotonic() + 12
                while client.proc.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                require(client.proc.poll() is not None,
                        "SessionEnd with blocked stdout exceeded bounded failure deadline")
            client.exit(seconds=18, success=success)
            if success:
                require(client.data.count(b"Q") == 1024*1024-len(marker),
                        "exact-cap native payload lost or repeated bytes")
            else:
                require(client.proc.returncode != 0, "invalid native frame reported success")
            require(not errors, "native fixture server failed: " + ','.join(errors))
            f.proxy.event("native_frame", case=name, bytes=len(frame), success=success)
        finally:
            stop.set()
            listener.close()
            thread.join(1)
            path.unlink(missing_ok=True)


def stdout_resume(f):
    client = f.attach()
    f.ready(client)
    start = len(client.data)
    client.command("python3 -c \"import os; os.write(1,b'S'*307200+b'SINK_DONE\\\\n')\"")
    # Do not consume the PTY; force partial writes/EAGAIN, then release it.
    time.sleep(2)
    require(client.proc.poll() is None, "temporary stdout stall disconnected client")
    client.expect(b"SINK_DONE", seconds=12, start=start)
    require(client.data[start:].count(b"S") == 307201, "stdout partial write lost or repeated bytes")
    f.detach(client)


def blocked_stdout(f):
    client = f.attach()
    f.ready(client)
    client.command("python3 -c \"import os; os.write(1,b'B'*524288)\"")
    # Never drain the master while the production 10s progress timer expires.
    deadline = time.monotonic() + 16
    while client.proc.poll() is None and time.monotonic() < deadline:
        time.sleep(.05)
    require(client.proc.poll() is not None, "blocked stdout did not enforce its progress deadline")
    require(client.proc.returncode != 0, "blocked stdout reported successful completion")
    client.exit(success=False)


def input_saturation(f):
    client = f.attach()
    f.ready(client)
    stats = f.path / "input-stats.json"
    code = "\n".join([
        "import os,time,tty,termios,select,json",
        "old=termios.tcgetattr(0); tty.setraw(0)",
        "print('SATURATION_READY',flush=True); time.sleep(2)",
        "received=0; deadline=time.monotonic()+3",
        "while time.monotonic()<deadline:",
        " if not select.select([0],[],[],.2)[0]: break",
        " received+=len(os.read(0,65536))",
        "termios.tcsetattr(0,termios.TCSANOW,old)",
        "open("+repr(str(stats))+",'w').write(json.dumps(dict(received=received)))",
        "print('SATURATION_DONE',flush=True)",
    ])
    client.command("python3 -c " + shlex.quote(code))
    client.expect(b"SATURATION_READY")
    source = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    source.connect(f.env["ZMX_DIR"] + "/e2e")
    try:
        data = b"i" * 8192
        frame = struct.pack("<BIxxx", 0, len(data)) + data
        source.sendall(frame * 128)
        client.expect(b"SATURATION_DONE", seconds=8)
    finally:
        source.close()
    received = json.loads(stats.read_text())["received"]
    require(0 < received < 1024*1024, "native stalled-PTY fixture did not expose inherited input loss")
    logs = b"".join(path.read_bytes() for path in (Path(f.env["ZMX_DIR"]) / "logs").glob("*.log"))
    require(b"pty input dropped" in logs, "core input cap diagnostic absent")
    f.proxy.event("input_saturation", submitted=1024*1024, received=received)
    f.detach(client)


def killed(f):
    client = f.attach()
    f.ready(client)
    f.core("kill", "--force", "e2e")
    client.exit(seconds=8)


def bootstrap_failures(f):
    authorized = f.path / "authorized_keys"
    original = authorized.read_text()
    authorized.write_text("")
    client = f.attach()
    client.exit(seconds=8, success=False)
    require(client.proc.returncode != 0, "failed SSH authentication reported success")
    authorized.write_text(original)
    (f.bin / "zmosh").unlink()
    client = f.attach()
    client.exit(seconds=8, success=False)
    require(client.proc.returncode != 0, "missing remote executable reported success")
    (f.bin / "zmosh").symlink_to(ROOT / "zig-out/bin/zmosh")
    relay = f.path / "relay.py"
    relay.write_text("print('malformed bootstrap')\n")
    client = f.attach()
    client.exit(seconds=8, success=False)
    require(client.proc.returncode != 0, "malformed bootstrap reported success")


def port_exhaustion(f):
    local = f.attach(local=True)
    f.ready(local, "PORT_TEST")
    pid = f.daemon_pid()
    reserved = []
    try:
        for port in range(60000, 61000):
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                sock.bind(("0.0.0.0", port))
            except OSError as exc:
                sock.close()
                require(exc.errno == errno.EADDRINUSE, "unexpected UDP reservation failure")
            else:
                reserved.append(sock)
        # Establish the underlying error independently of SSH's intentionally
        # bounded generic bootstrap error; no bootstrap key is published on bind failure.
        worker = subprocess.run([str(ROOT / "zig-out/bin/zmosh"), "--gateway", "e2e"],
                                env=f.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        require(worker.returncode != 0 and b"AddressInUse" in worker.stderr,
                "exhausted UDP range did not report AddressInUse")
        client = f.attach()
        started = time.monotonic()
        client.exit(seconds=6, success=False)
        require(client.proc.returncode != 0, "SSH bootstrap succeeded with exhausted UDP ports")
        require(f.daemon_pid() == pid, "UDP exhaustion replaced the native session")
        start = len(local.data)
        local.command("printf 'PORT_SURVIVED_%s\\n' OK")
        local.expect(b"PORT_SURVIVED_OK", start=start)
        for process in f.owned_pids():
            try:
                require(b"--gateway" not in Path(f"/proc/{process}/cmdline").read_bytes().split(b"\0"),
                        "failed UDP bootstrap leaked a gateway")
            except FileNotFoundError:
                pass
        f.proxy.event("udp_port_exhaustion", reserved=len(reserved),
                      ssh_failure_seconds=round(time.monotonic()-started, 3))
    finally:
        for sock in reserved:
            sock.close()


def session_end_loss(f):
    for label, drops in (("first", 1), ("all", -1)):
        client = f.attach()
        f.ready(client, "END_" + label)
        settle(client)
        f.proxy.end_drops = drops
        before = f.proxy.end_drop_count
        started = time.monotonic()
        f.core("kill", "--force", "e2e")
        if label == "all":
            while client.proc.poll() is None:
                client.pump(.05)
                elapsed = time.monotonic() - started
                if elapsed > 6:
                    for pid in f.owned_pids():
                        try:
                            require(b"--gateway" not in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0"),
                                    "gateway exceeded five-second termination drain plus grace")
                        except FileNotFoundError:
                            pass
                # The last heartbeat may arrive during the five-second drain;
                # peer-dead is measured from that authenticated receive time.
                require(elapsed < 22, "client exceeded drain plus peer-dead deadline")
                require(f.proxy.last_down_forwarded is not None and
                        time.monotonic() - f.proxy.last_down_forwarded < 16,
                        "client exceeded fifteen seconds since last authenticated packet plus grace")
        client.exit(seconds=8, success=label == "first")
        require(f.proxy.end_drop_count > before, "SessionEnd fault did not match an actual record")
        if label == "all":
            require(client.proc.returncode != 0, "missing SessionEnd reported successful termination")
        f.proxy.event("session_end_loss", mode=label, dropped=f.proxy.end_drop_count-before,
                      exit_seconds=round(time.monotonic()-started, 3))
        f.proxy.end_drops = 0


def blocked_udp(f):
    f.proxy.outage(25)
    client = f.attach()
    client.exit(seconds=20, success=False)
    require(client.proc.returncode != 0, "blocked UDP reported success")


def signal_restore(f):
    for sig in (signal.SIGINT, signal.SIGTERM):
        client = f.attach()
        f.ready(client, sig.name)
        client.proc.send_signal(sig)
        client.exit(success=False)


SCENARIOS = dict(bootstrap=bootstrap, first_attach=first_attach, preinit_noisy=preinit_noisy,
                 recovery=recovery, packets=packets,
                 roaming=roaming, resize=resize, final_output=final_output,
                 restoration=restoration, overload=overload, native_boundaries=native_boundaries,
                 stdout_resume=stdout_resume, blocked_stdout=blocked_stdout,
                 input_saturation=input_saturation, killed=killed, bootstrap_failures=bootstrap_failures,
                 session_end_loss=session_end_loss, blocked_udp=blocked_udp, signal_restore=signal_restore,
                 port_exhaustion=port_exhaustion)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario', choices=['all', *SCENARIOS], default='all')
    args = parser.parse_args()
    selected = SCENARIOS if args.scenario == 'all' else {args.scenario: SCENARIOS[args.scenario]}
    failed = False
    for name, scenario in selected.items():
        fixture = Fixture()
        started = time.monotonic()
        try:
            signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError("45s scenario deadline")))
            signal.alarm(45)
            fixture.start()
            scenario(fixture)
            print(json.dumps(dict(scenario=name, result='PASS', seconds=round(time.monotonic()-started, 3),
                                  schedule=fixture.proxy.events)), flush=True)
        except Exception as exc:
            failed = True
            # Never print raw terminal data, SSH connect records, or credentials.
            print(json.dumps(dict(scenario=name, result='FAIL', error=str(exc),
                                  seconds=round(time.monotonic()-started, 3),
                                  schedule=fixture.proxy.events)), flush=True)
        finally:
            signal.alarm(0)
            fixture.close()
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
