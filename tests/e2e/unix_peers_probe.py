#!/usr/bin/env python3
"""List the clients connected to a Unix socket path, as socket inode numbers.

A server's end of each connection it accepted carries the path it listens on; the client's
end has no name. The kernel's sock_diag interface (NETLINK_SOCK_DIAG, linux/unix_diag.h)
reports both ends, each with its peer, for every Unix socket of the network namespace it is
asked from, so this runs in a container that shares the test container's network namespace.
A process holds the client's end of a connection if /proc/PID/fd links to socket:[INODE] for
one of the inodes printed.

Prints JSON: {"path", "listening": whether a socket listens on PATH, "clients": the inode of
the client's end of each connection to PATH, sorted}.

Usage: unix_peers_probe.py PATH
"""

import json
import socket
import struct
import sys

NETLINK_SOCK_DIAG = 4
SOCK_DIAG_BY_FAMILY = 20
NLMSG_ERROR = 2
NLMSG_DONE = 3
NLM_F_REQUEST = 0x1
NLM_F_DUMP = 0x300
UDIAG_SHOW_NAME = 0x1
UDIAG_SHOW_PEER = 0x4
UNIX_DIAG_NAME = 0
UNIX_DIAG_PEER = 2
TCP_ESTABLISHED = 1
TCP_LISTEN = 10
NLMSG_HEADER = struct.Struct("=IHHII")  # length, type, flags, sequence, port ID
# unix_diag_req: family, protocol, padding, states, inode, show, cookie
UNIX_DIAG_REQ = struct.Struct("=BBHIIIII")
# unix_diag_msg: family, type, state, padding, inode, cookie
UNIX_DIAG_MSG = struct.Struct("=BBBBIII")
RTATTR_HEADER = struct.Struct("=HH")  # length, type


def align4(n: int) -> int:
    return (n + 3) & ~3


def dump_request(sequence: int = 1) -> bytes:
    """A request for every Unix socket in any state, with its name and peer."""
    body = UNIX_DIAG_REQ.pack(
        socket.AF_UNIX, 0, 0, 0xFFFFFFFF, 0, UDIAG_SHOW_NAME | UDIAG_SHOW_PEER, 0xFFFFFFFF,
        0xFFFFFFFF,
    )  # fmt: skip
    flags = NLM_F_REQUEST | NLM_F_DUMP
    return (
        NLMSG_HEADER.pack(NLMSG_HEADER.size + len(body), SOCK_DIAG_BY_FAMILY, flags, sequence, 0)
        + body
    )


def parse_sockets(data: bytes) -> tuple[list[dict], bool]:
    """The sockets in DATA, one netlink read, as dicts {inode, state, name, peer}; and whether
    the dump is done. Raises OSError for a netlink error message, ValueError if malformed."""
    sockets = []
    offset = 0
    while offset < len(data):
        if len(data) - offset < NLMSG_HEADER.size:
            raise ValueError(f"truncated netlink header at {offset}")
        length, kind, _, _, _ = NLMSG_HEADER.unpack_from(data, offset)
        if length < NLMSG_HEADER.size or offset + length > len(data):
            raise ValueError(f"netlink message length {length} at {offset} of {len(data)}")
        body = data[offset + NLMSG_HEADER.size : offset + length]
        if kind == NLMSG_DONE:
            return sockets, True
        if kind == NLMSG_ERROR:
            (error,) = struct.unpack_from("=i", body)
            raise OSError(-error, f"sock_diag: error {-error}")
        if kind != SOCK_DIAG_BY_FAMILY or len(body) < UNIX_DIAG_MSG.size:
            raise ValueError(f"unexpected netlink message type {kind}, {len(body)} bytes")
        _, _, state, _, inode, _, _ = UNIX_DIAG_MSG.unpack_from(body)
        entry = {"inode": inode, "state": state, "name": None, "peer": None}
        position = UNIX_DIAG_MSG.size
        while len(body) - position >= RTATTR_HEADER.size:
            attr_length, attr_type = RTATTR_HEADER.unpack_from(body, position)
            if attr_length < RTATTR_HEADER.size or position + attr_length > len(body):
                raise ValueError(f"attribute length {attr_length} at {position}")
            payload = body[position + RTATTR_HEADER.size : position + attr_length]
            if attr_type == UNIX_DIAG_NAME:
                # A path name ends at its first NUL; an abstract name starts with one.
                entry["name"] = payload.split(b"\0", 1)[0].decode("utf-8", "replace") or None
            elif attr_type == UNIX_DIAG_PEER:
                (entry["peer"],) = struct.unpack("=I", payload)
            position += align4(attr_length)
        sockets.append(entry)
        offset += align4(length)
    return sockets, False


def clients(sockets: list[dict], path: str) -> tuple[bool, list[int]]:
    """Whether a socket listens on PATH, and the client inodes of its connections."""
    listening = any(s["name"] == path and s["state"] == TCP_LISTEN for s in sockets)
    peers = sorted(
        s["peer"]
        for s in sockets
        if s["name"] == path and s["state"] == TCP_ESTABLISHED and s["peer"] is not None
    )
    return listening, peers


def dump() -> list[dict]:
    with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_SOCK_DIAG) as sock:
        sock.settimeout(10)
        sock.send(dump_request())
        found = []
        done = False
        while not done:
            sockets, done = parse_sockets(sock.recv(1 << 16))
            found += sockets
        return found


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    listening, peers = clients(dump(), argv[0])
    print(json.dumps({"path": argv[0], "listening": listening, "clients": peers}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
