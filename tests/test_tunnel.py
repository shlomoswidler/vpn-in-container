"""Tests for tests/browser/tunnel.py, which forwards TCP connections to a command's stdio.

tests/browser/run.sh reaches a --network none container's web UI through it, so each
connection must get its own command, and bytes must arrive unchanged and in order both ways,
with each side's end of stream passed on.
Run: python3 -m unittest discover -s tests
"""

import os
import socket
import subprocess
import sys
import threading
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TUNNEL = REPO_ROOT / "tests" / "browser" / "tunnel.py"
# Copies stdin to stdout, each byte XOR 0xFF (so a byte passed through unchanged would fail),
# then writes its PID, and exits at end of input.
TRANSFORM = (
    "import os, sys\n"
    "while data := sys.stdin.buffer.read1(65536):\n"
    "    sys.stdout.buffer.write(bytes(b ^ 0xFF for b in data)); sys.stdout.buffer.flush()\n"
    "sys.stdout.buffer.write(b'pid=%d' % os.getpid())\n"
)


def read_all(connection: socket.socket) -> bytes:
    data = b""
    while chunk := connection.recv(65536):
        data += chunk
    return data


class TunnelTests(unittest.TestCase):
    def start(self, *command: str) -> int:
        self.tunnel = subprocess.Popen(
            [sys.executable, "-I", str(TUNNEL), "0", *command],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )  # fmt: skip
        self.addCleanup(self.stop)
        line = self.tunnel.stdout.readline()
        self.assertTrue(line.startswith("listening on 127.0.0.1:"), line)
        return int(line.rsplit(":", 1)[1])

    def stop(self):
        self.tunnel.kill()
        self.tunnel.wait()
        self.tunnel.stdout.close()
        self.tunnel.stderr.close()

    def exchange(self, port: int, payload: bytes) -> bytes:
        with socket.create_connection(("127.0.0.1", port), timeout=20) as connection:
            sender = threading.Thread(
                target=lambda: (connection.sendall(payload), connection.shutdown(socket.SHUT_WR))
            )
            sender.start()
            data = read_all(connection)
            sender.join()
            return data

    def test_bytes_pass_both_ways_and_each_connection_gets_its_own_command(self):
        port = self.start(sys.executable, "-I", "-c", TRANSFORM)
        payloads = [os.urandom(300_000), bytes(range(256)) * 10, b""]
        results = [None] * len(payloads)

        def run(i):
            results[i] = self.exchange(port, payloads[i])

        threads = [threading.Thread(target=run, args=(i,)) for i in range(len(payloads))]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)
        pids = set()
        for payload, result in zip(payloads, results, strict=True):
            body, _, pid = result.rpartition(b"pid=")
            self.assertEqual(body, bytes(b ^ 0xFF for b in payload))
            pids.add(pid)
        self.assertEqual(len(pids), len(payloads))

    def test_the_command_ending_ends_the_connection(self):
        port = self.start(sys.executable, "-I", "-c", "print('bye')")
        with socket.create_connection(("127.0.0.1", port), timeout=20) as connection:
            self.assertEqual(read_all(connection), b"bye\n")

    def test_wrong_arguments_print_the_usage(self):
        for args in ([], ["8080"], ["port", "cat"]):
            with self.subTest(args=args):
                result = subprocess.run(
                    [sys.executable, "-I", str(TUNNEL), *args],
                    capture_output=True, text=True, timeout=30, check=False,
                )  # fmt: skip
                self.assertEqual(result.returncode, 2)
                self.assertIn("Usage: tunnel.py PORT COMMAND...", result.stderr)


if __name__ == "__main__":
    unittest.main()
