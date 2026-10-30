#!/usr/bin/env python3
"""Read the cursor a VNC server shows at a given pointer position.

A minimal RFB 3.8 client that advertises the cursor pseudo-encodings noVNC
uses (VMware cursor, then Cursor), moves the pointer to (X, Y), and writes the
cursor shown there as raw R, G, B, A bytes to OUT.rgba. It prints a JSON
summary: {"w", "h", "hotx", "hoty", "encoding"}.

TigerVNC sends an empty cursor first and a real one only after the pointer
moves, so until a real cursor arrives each empty update nudges the pointer by
one pixel (staying at the requested spot to within 1px). The first real
cursor is usually the one from the pointer's previous position, because the
application changes its cursor only after it sees the motion, so the probe
keeps reading until the cursor has not changed for SETTLE_S and reports it.
An empty last update, or EMPTY_LIMIT empty updates and nothing else, is
reported as w = h = 0: what an invisible cursor (CSS "none") looks like.

Usage: rfb_cursor_probe.py HOST PORT X Y OUT
"""

import json
import socket
import struct
import sys
import time
from pathlib import Path

VMWARE_CURSOR = 0x574D5664
RICH_CURSOR = -239
DESKTOP_SIZE = -223
RAW = 0
EMPTY_LIMIT = 6
SETTLE_S = 1.5
MAX_WAIT_S = 15
READ_TIMEOUT_S = 10
EMPTY_CURSOR = {"w": 0, "h": 0, "hotx": 0, "hoty": 0, "encoding": "vmware", "rgba": b""}


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("server closed the connection")
        buf += chunk
    return buf


def handshake(sock: socket.socket) -> tuple[int, int]:
    recv_exact(sock, 12)
    sock.sendall(b"RFB 003.008\n")
    (count,) = struct.unpack("B", recv_exact(sock, 1))
    if 1 not in recv_exact(sock, count):
        raise RuntimeError("server does not offer security type None")
    sock.sendall(b"\x01")
    if struct.unpack(">I", recv_exact(sock, 4))[0] != 0:
        raise RuntimeError("security handshake failed")
    sock.sendall(b"\x01")  # shared session
    width, height = struct.unpack(">HH", recv_exact(sock, 4))
    recv_exact(sock, 16)  # server pixel format
    (name_len,) = struct.unpack(">I", recv_exact(sock, 4))
    recv_exact(sock, name_len)
    # 32bpp little-endian true color, as noVNC requests.
    pixel_format = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    sock.sendall(struct.pack(">B3x", 0) + pixel_format)
    encodings = [RAW, DESKTOP_SIZE, VMWARE_CURSOR, RICH_CURSOR]
    sock.sendall(
        struct.pack(">BxH", 2, len(encodings)) + b"".join(struct.pack(">i", e) for e in encodings)
    )
    return width, height


def move(sock: socket.socket, x: int, y: int) -> None:
    sock.sendall(struct.pack(">BBHH", 5, 0, x, y))


def request_update(sock: socket.socket, width: int, height: int, incremental: int) -> None:
    sock.sendall(struct.pack(">BBHHHH", 3, incremental, 0, 0, width, height))


def read_rect_cursor(sock: socket.socket, hotx: int, hoty: int, w: int, h: int, encoding: int):
    """Read one cursor rectangle; return its cursor dict (empty if 0x0)."""
    if encoding == VMWARE_CURSOR:
        cursor_type, _pad = struct.unpack("BB", recv_exact(sock, 2))
        if w == 0 or h == 0:
            return EMPTY_CURSOR
        if cursor_type != 1:
            raise RuntimeError(f"VMware cursor type {cursor_type} is not alpha")
        # Big-endian 0xRRGGBBAA per pixel: the R, G, B, A bytes noVNC uses.
        rgba = recv_exact(sock, w * h * 4)
        return {"w": w, "h": h, "hotx": hotx, "hoty": hoty, "encoding": "vmware", "rgba": rgba}
    # Rich cursor: pixels in the requested format (B, G, R, X) plus a 1-bit mask.
    if w == 0 or h == 0:
        return EMPTY_CURSOR
    pixels = recv_exact(sock, w * h * 4)
    row_bytes = (w + 7) // 8
    mask = recv_exact(sock, row_bytes * h)
    rgba = bytearray()
    for i in range(w * h):
        row, col = divmod(i, w)
        visible = mask[row * row_bytes + col // 8] >> (7 - col % 8) & 1
        b, g, r = pixels[i * 4 : i * 4 + 3]
        rgba += bytes((r, g, b, 255 if visible else 0))
    return {"w": w, "h": h, "hotx": hotx, "hoty": hoty, "encoding": "rich", "rgba": bytes(rgba)}


def read_cursor(sock: socket.socket, x: int, y: int, width: int, height: int) -> dict:
    """Return the cursor shown at (x, y) once it settles (empty if none).

    Settled means no cursor change for SETTLE_S. Screen updates do not count,
    so a busy desktop cannot keep the probe waiting; MAX_WAIT_S bounds a
    cursor that keeps changing (an animated one, for example).
    """
    latest = None
    empties = 0
    last_change = time.monotonic()
    deadline = last_change + MAX_WAIT_S
    move(sock, x, y)
    request_update(sock, width, height, 0)
    while True:
        now = time.monotonic()
        if now - last_change >= SETTLE_S:
            return latest or EMPTY_CURSOR
        if now >= deadline:
            raise RuntimeError(f"cursor still changing after {MAX_WAIT_S} s")
        # Wait for the next message only until the cursor would count as settled;
        # once a message starts, read the rest of it with the normal timeout.
        sock.settimeout(SETTLE_S - (now - last_change))
        try:
            (msg_type,) = struct.unpack("B", recv_exact(sock, 1))
        except TimeoutError:
            continue
        sock.settimeout(READ_TIMEOUT_S)
        if msg_type == 2:  # bell
            continue
        if msg_type == 3:  # server cut text
            recv_exact(sock, 3)
            recv_exact(sock, struct.unpack(">I", recv_exact(sock, 4))[0])
            continue
        if msg_type != 0:
            raise RuntimeError(f"unexpected server message {msg_type}")
        _pad, rects = struct.unpack(">BH", recv_exact(sock, 3))
        for _ in range(rects):
            hotx, hoty, w, h, encoding = struct.unpack(">HHHHi", recv_exact(sock, 12))
            if encoding == RAW:
                recv_exact(sock, w * h * 4)
            elif encoding == DESKTOP_SIZE:
                continue
            elif encoding in (VMWARE_CURSOR, RICH_CURSOR):
                cursor = read_rect_cursor(sock, hotx, hoty, w, h, encoding)
                if cursor is EMPTY_CURSOR and latest is None:
                    empties += 1
                    if empties >= EMPTY_LIMIT:
                        return EMPTY_CURSOR
                    move(sock, x + empties % 2, y)
                elif cursor != latest:
                    latest = cursor
                last_change = time.monotonic()
            else:
                raise RuntimeError(f"unexpected encoding {encoding}")
        request_update(sock, width, height, 1)


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    host, port, x, y, out = argv[0], int(argv[1]), int(argv[2]), int(argv[3]), Path(argv[4])
    with socket.create_connection((host, port), timeout=READ_TIMEOUT_S) as sock:
        width, height = handshake(sock)
        cursor = dict(read_cursor(sock, x, y, width, height))
    out.with_suffix(".rgba").write_bytes(cursor.pop("rgba"))
    print(json.dumps(cursor))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
