"""Tests for tests/e2e/unix_peers_probe.py, which lists the clients of a Unix socket path.

The netlink replies are built here from linux/netlink.h and linux/unix_diag.h, independently
of the probe's code. The probe itself needs Linux (sock_diag); tests/e2e/run.sh runs it.
Run: python3 -m unittest discover -s tests
"""

import importlib.util
import socket
import struct
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROBE = REPO_ROOT / "tests" / "e2e" / "unix_peers_probe.py"
ESTABLISHED, LISTEN = 1, 10
PATH = "/tmp/pulseaudio.sock"


def load_probe():
    spec = importlib.util.spec_from_file_location("unix_peers_probe", PROBE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def attribute(kind: int, payload: bytes) -> bytes:
    """An rtattr, padded to 4 bytes."""
    data = struct.pack("=HH", 4 + len(payload), kind) + payload
    return data + bytes(-len(data) % 4)


def netlink(kind: int, body: bytes) -> bytes:
    data = struct.pack("=IHHII", 16 + len(body), kind, 2, 1, 0) + body
    return data + bytes(-len(data) % 4)


def unix_socket(inode: int, state: int, name: bytes | None = None, peer: int | None = None):
    """One SOCK_DIAG_BY_FAMILY reply: a stream socket with its name and peer attributes."""
    body = struct.pack("=BBBBIII", socket.AF_UNIX, 1, state, 0, inode, 0, 0)
    if name is not None:
        body += attribute(0, name)
    if peer is not None:
        body += attribute(2, struct.pack("=I", peer))
    return netlink(20, body)


DONE = netlink(3, struct.pack("=i", 0))


class ParseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = load_probe()

    def test_the_clients_of_the_path_are_listed(self):
        data = (
            unix_socket(100, LISTEN, PATH.encode())
            + unix_socket(101, ESTABLISHED, PATH.encode(), peer=201)  # the recorder's
            + unix_socket(201, ESTABLISHED, peer=101)
            + unix_socket(102, ESTABLISHED, PATH.encode(), peer=202)  # Firefox's
            + unix_socket(300, LISTEN, b"/tmp/vnc-audio.sock")
            + unix_socket(301, ESTABLISHED, b"/tmp/vnc-audio.sock", peer=401)
            + unix_socket(500, ESTABLISHED, b"\0abstract", peer=501)
        )
        sockets, done = self.probe.parse_sockets(data + DONE)
        self.assertTrue(done)
        self.assertEqual(len(sockets), 7)
        self.assertEqual(self.probe.clients(sockets, PATH), (True, [201, 202]))
        self.assertEqual(self.probe.clients(sockets, "/tmp/vnc-audio.sock"), (True, [401]))
        self.assertIsNone(sockets[-1]["name"])

    def test_nothing_listening_and_no_clients(self):
        sockets, done = self.probe.parse_sockets(unix_socket(1, ESTABLISHED, peer=2))
        self.assertFalse(done)
        self.assertEqual(self.probe.clients(sockets, PATH), (False, []))

    def test_a_name_is_read_up_to_its_nul(self):
        sockets, _ = self.probe.parse_sockets(unix_socket(1, LISTEN, PATH.encode() + b"\0junk"))
        self.assertEqual(sockets[0]["name"], PATH)

    def test_a_netlink_error_raises(self):
        with self.assertRaises(OSError) as raised:
            self.probe.parse_sockets(netlink(2, struct.pack("=i", -1) + bytes(16)))
        self.assertEqual(raised.exception.errno, 1)

    def test_malformed_replies_raise(self):
        whole = unix_socket(1, LISTEN, PATH.encode())
        # The name attribute starts after the netlink header and unix_diag_msg (16 bytes each).
        bad_attribute = whole[:32] + struct.pack("=H", 200) + whole[34:]
        for name, data in {
            "truncated header": whole[:10],
            "length past the end": whole[:-4],
            "attribute past the end": bad_attribute,
            "unknown type": netlink(99, bytes(16)),
        }.items():
            with self.subTest(name), self.assertRaises(ValueError):
                self.probe.parse_sockets(data)

    def test_the_request_asks_for_every_unix_socket_with_name_and_peer(self):
        request = self.probe.dump_request()
        length, kind, flags, _, _ = struct.unpack_from("=IHHII", request)
        self.assertEqual((length, kind, flags), (len(request), 20, 0x301))
        family, protocol, _, states, inode, show = struct.unpack_from("=BBHIII", request, 16)
        self.assertEqual((family, protocol, states, inode), (socket.AF_UNIX, 0, 0xFFFFFFFF, 0))
        self.assertEqual(show & 0x5, 0x5)  # UDIAG_SHOW_NAME | UDIAG_SHOW_PEER


if __name__ == "__main__":
    unittest.main()
