#!/usr/bin/env python3
"""A minimal STUN server (RFC 8489 Binding only) for tests/e2e/run.sh.

Answers every Binding request on 0.0.0.0:PORT with a success response whose
XOR-MAPPED-ADDRESS is MAPPED_IP and the request's source port, as a NAT would.
The test uses an address no interface has (a documentation address), so a
server-reflexive candidate is told apart from host candidates by its address.

Usage: stun_server.py PORT MAPPED_IP
"""

import ipaddress
import socket
import struct
import sys

MAGIC_COOKIE = 0x2112A442
BINDING_REQUEST = 0x0001
BINDING_SUCCESS = 0x0101
XOR_MAPPED_ADDRESS = 0x0020
HEADER = struct.Struct("!HHI12s")  # type, length, magic cookie, transaction ID


def binding_response(request: bytes, mapped_ip: str, port: int) -> bytes | None:
    """The success response to REQUEST, or None if it is not a STUN Binding request."""
    if len(request) < HEADER.size:
        return None
    kind, _, cookie, transaction = HEADER.unpack_from(request)
    if kind != BINDING_REQUEST or cookie != MAGIC_COOKIE:
        return None
    address = int(ipaddress.IPv4Address(mapped_ip)) ^ MAGIC_COOKIE
    value = struct.pack("!BBHI", 0, 1, port ^ (MAGIC_COOKIE >> 16), address)
    attribute = struct.pack("!HH", XOR_MAPPED_ADDRESS, len(value)) + value
    return HEADER.pack(BINDING_SUCCESS, len(attribute), MAGIC_COOKIE, transaction) + attribute


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    port, mapped_ip = int(argv[0]), argv[1]
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.bind(("0.0.0.0", port))
        while True:
            request, source = server.recvfrom(2048)
            response = binding_response(request, mapped_ip, source[1])
            if response is not None:
                server.sendto(response, source)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
