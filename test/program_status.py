"""Socket and PTY helpers for the OSC 7501 Program Status tests in reattach.bats."""
import os
from pathlib import Path
import re
import select
import tty
import socket
import struct
import subprocess
import sys
import time


HEADER = struct.Struct('<BBHI')
CLEAR = b'\x1b]7501;state=clear\x1b\\'
REPORT = re.compile(rb'\x1b\]7501;([^\x07\x1b]*)(?:\x07|\x1b\\)')


def expect_reports(output, expected):
    actual = REPORT.findall(output)
    assert actual == expected, (actual, expected)


def producer(folder):
    # Files control PTY output without shell echo or terminal-input side effects.
    for index in range(1000):
        command = folder / str(index)
        while not command.exists():
            time.sleep(0.01)
        os.write(1, command.read_bytes())
        (folder / ('sent-' + str(index))).touch()


CAPABILITY_REPLY = b'\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth'


def capability_producer(folder):
    tty.setraw(0)
    for index, terminator in enumerate((b'\x07', b'\x1b\\')):
        while not (folder / ('probe-' + str(index))).exists():
            time.sleep(0.01)
        os.write(1, b'\x1b]7501;?' + terminator + b'\x1b[c')
        expected = CAPABILITY_REPLY + terminator + b'\x1b[?62;22c'
        received = b''
        deadline = time.monotonic() + 60
        while len(received) < len(expected):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([0], [], [], remaining)[0]:
                raise AssertionError(('missing capability reply', received))
            received += os.read(0, 4096)
        assert received == expected, (received, expected)
        os.write(1, b'\x1b]7501;state=working:id=probe-' + str(index).encode() + b'\x07\r\nprobe-ready-' + str(index).encode() + b'\r\n')
    while True:
        time.sleep(1)


class ProgramStatus:
    def __init__(self, exe, folder):
        self.folder = Path(folder) / 'program-status'
        self.folder.mkdir()
        self.exe = exe
        self.env = dict(os.environ, SHELL='/bin/bash')
        self.env.pop('ZMX_SESSION', None)
        self.env.pop('ZMX_SESSION_PREFIX', None)
        self.clients = []
        self.index = 0

    def start(self, capability=False):
        mode = '--capability-producer' if capability else '--producer'
        self.run_zmx('run', 'status', '-d', sys.executable, str(Path(__file__).resolve()), mode, str(self.folder))

    def run_zmx(self, *args, env=None):
        result = subprocess.run([self.exe, *args], env=self.env if env is None else env, capture_output=True, timeout=60)
        assert result.returncode == 0, result.stderr.decode(errors='replace')
        return result.stdout

    def close_clients(self):
        for client in self.clients:
            client.close()

    def emit(self, data, complete=True):
        index = self.index
        self.index += 1
        marker = ('seen_%d' % index).encode()
        command = self.folder / str(index)
        staging = command.with_suffix('.tmp')
        staging.write_bytes(data + (b'\r\n' + marker + b'\r\n' if complete else b''))
        staging.rename(command)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if (self.folder / ('sent-' + str(index))).exists():
                if not complete or marker in self.run_zmx('history', 'status'):
                    return marker
            time.sleep(0.01)
        raise AssertionError('producer output did not reach daemon')

    def message(self, client):
        def read_exact(size):
            data = b''
            while len(data) < size:
                chunk = client.recv(size - len(data))
                assert chunk, 'daemon closed client socket'
                data += chunk
            return data
        tag, version, reserved, length = HEADER.unpack(read_exact(HEADER.size))
        assert version == 1, (version, 1)
        assert reserved == 0, (reserved, 0)
        assert length < 16 * 1024 * 1024, (length, 16 * 1024 * 1024)
        return tag, read_exact(length)

    def output_until(self, client, marker):
        data = b''
        while marker not in data:
            tag, payload = self.message(client)
            if tag == 1:
                data += payload
        return data

    def attach(self):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.clients.append(client)
        client.settimeout(60)
        client.connect(str(Path(self.env['ZMX_DIR']) / 'status'))
        size = struct.pack('<HHHH', 24, 80, 0, 0)
        client.sendall(HEADER.pack(7, 1, 0, len(size)) + size)
        return client, self.output_until(client, CLEAR)

    def current_records_detached_updates_and_private_replay(self):
        self.emit(b'\x1b]7501;state=working\x07\x1b]7501;state=blocked:id=worker:kind=permission\x07')
        first, initial = self.attach()
        expect_reports(initial, [b'state=clear', b'state=working', b'state=blocked:id=worker:kind=permission'])
        second, snapshot = self.attach()
        expect_reports(snapshot, REPORT.findall(initial))
        marker = self.emit(b'\x1b]7501;state=idle\x07')
        expect_reports(self.output_until(first, marker), [b'state=idle'])
        expect_reports(self.output_until(second, marker), [b'state=idle'])
        first.close()
        second.close()
        self.emit(b'\x1b]7501;state=done:id=worker\x07\x1b]7501;state=error:id=other\x07\x1b]7501;state=clear:id=other\x07')
        third, snapshot = self.attach()
        expect_reports(snapshot, [b'state=clear', b'state=idle', b'state=done:id=worker'])
        third.close()
        self.emit(b'\x1b]7501;state=clear\x07')
        _, snapshot = self.attach()
        expect_reports(snapshot, [b'state=clear'])

    def pending_report_continues_after_screen_restore(self):
        self.emit(b'screen survives\x1b]7501;state=idle\x07')
        monitor, _ = self.attach()
        prefix = b'\x1b]7501;state=blocked:id=worker:kind=permission'
        self.emit(prefix, complete=False)
        # Seeing the prefix on an attached client proves the daemon consumed it
        # before we request the new snapshot, without inserting a VT terminator.
        self.output_until(monitor, prefix)
        target, snapshot = self.attach()
        assert b'screen survives' in snapshot, (b'screen survives', snapshot)
        assert snapshot.endswith(prefix), repr(snapshot)
        marker = self.emit(b'\x07')
        replay_and_live = snapshot + self.output_until(target, marker)
        expect_reports(replay_and_live, [b'state=clear', b'state=idle', b'state=blocked:id=worker:kind=permission'])


    def detached_agent_starts_reporting(self):
        for index in range(2):
            (self.folder / ('probe-' + str(index))).touch()
            marker = ('probe-ready-' + str(index)).encode()
            deadline = time.monotonic() + 65
            while marker not in self.run_zmx('history', 'status'):
                assert time.monotonic() < deadline, 'agent did not receive capability reply'
                time.sleep(0.01)
            client, snapshot = self.attach()
            expected = [b'state=clear'] + [b'state=working:id=probe-' + str(task).encode() for task in range(index + 1)]
            expect_reports(snapshot, expected)
            # Wait for terminal detachment to be processed before the next probe.
            self.run_zmx('detach', env=dict(self.env, ZMX_SESSION='status'))
            while client.recv(65536):
                pass
            client.close()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--producer':
        producer(Path(sys.argv[2]))
    elif len(sys.argv) > 1 and sys.argv[1] == '--capability-producer':
        capability_producer(Path(sys.argv[2]))
    else:
        if not __debug__:
            raise RuntimeError('program-status checks require Python assertions')
        scenario, exe, folder = sys.argv[1:]
        session = ProgramStatus(exe, folder)
        try:
            session.start(capability=scenario == 'detached-capability')
            if scenario == 'records':
                session.current_records_detached_updates_and_private_replay()
            elif scenario == 'pending-report':
                session.pending_report_continues_after_screen_restore()
            elif scenario == 'detached-capability':
                session.detached_agent_starts_reporting()
            else:
                raise ValueError('unknown program-status scenario ' + scenario)
        finally:
            session.close_clients()
