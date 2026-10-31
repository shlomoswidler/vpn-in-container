"""Tests for tests/e2e/stun_server.py, the STUN server of the e2e WebRTC scenario.

The response is decoded here independently of the server's code (RFC 8489: the header,
then XOR-MAPPED-ADDRESS, whose port and address are XORed with the magic cookie).
Run: python3 -m unittest discover -s tests
"""

import importlib.util
import ipaddress
import os
import socket
import struct
import subprocess
import sys
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
STUN_SERVER = REPO_ROOT / "tests" / "e2e" / "stun_server.py"
COOKIE = 0x2112A442


def load_binding_response():
    spec = importlib.util.spec_from_file_location("stun_server", STUN_SERVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.binding_response


def request(transaction: bytes, kind: int = 0x0001, cookie: int = COOKIE) -> bytes:
    return struct.pack("!HHI", kind, 0, cookie) + transaction


def decode(response: bytes) -> tuple[int, bytes, str, int]:
    """(message type, transaction ID, mapped address, mapped port) of a response."""
    kind, length, cookie = struct.unpack_from("!HHI", response)
    assert cookie == COOKIE, hex(cookie)
    assert length == len(response) - 20, (length, len(response))
    attribute, size = struct.unpack_from("!HH", response, 20)
    assert (attribute, size) == (0x0020, 8), (attribute, size)
    _, family, xport, xaddress = struct.unpack_from("!BBHI", response, 24)
    assert family == 1, family
    address = str(ipaddress.IPv4Address(xaddress ^ COOKIE))
    return kind, response[8:20], address, xport ^ (COOKIE >> 16)


class BindingResponseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binding_response = staticmethod(load_binding_response())

    def test_a_binding_request_gets_the_mapped_address_and_port(self):
        transaction = bytes(range(12))
        response = self.binding_response(request(transaction), "203.0.113.7", 54321)
        self.assertEqual(decode(response), (0x0101, transaction, "203.0.113.7", 54321))

    def test_anything_else_gets_no_answer(self):
        transaction = bytes(12)
        for data in (
            request(transaction, kind=0x0101),  # a response, not a request
            request(transaction, cookie=0),  # no magic cookie (RFC 3489 or not STUN)
            b"\x00\x01\x00\x00",  # shorter than a header
            b"",
        ):
            with self.subTest(data=data):
                self.assertIsNone(self.binding_response(data, "203.0.113.7", 1))


class ServerTests(unittest.TestCase):
    def test_the_server_answers_over_udp(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.bind(("127.0.0.1", 0))
            free = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            free.bind(("127.0.0.1", 0))
            port = free.getsockname()[1]
            free.close()
            server = subprocess.Popen(
                [sys.executable, "-I", str(STUN_SERVER), str(port), "198.51.100.9"],
                stderr=subprocess.PIPE,
            )
            try:
                probe.settimeout(0.5)
                transaction = os.urandom(12)
                deadline = time.monotonic() + 10
                while True:
                    probe.sendto(request(transaction), ("127.0.0.1", port))
                    try:
                        response = probe.recv(2048)
                        break
                    except TimeoutError:
                        if server.poll() is not None:
                            self.fail(f"the server exited: {server.stderr.read()!r}")
                        self.assertLess(time.monotonic(), deadline, "no answer in 10 s")
                own_port = probe.getsockname()[1]
                self.assertEqual(decode(response), (0x0101, transaction, "198.51.100.9", own_port))
            finally:
                server.kill()
                server.wait()
                server.stderr.close()

    def test_wrong_arguments_print_the_usage(self):
        result = subprocess.run(
            [sys.executable, "-I", str(STUN_SERVER)],
            capture_output=True, text=True, timeout=30, check=False,
        )  # fmt: skip
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage: stun_server.py PORT MAPPED_IP", result.stderr)


if __name__ == "__main__":
    unittest.main()
