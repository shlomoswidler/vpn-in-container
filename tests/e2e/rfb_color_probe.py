#!/usr/bin/env python3
"""Count the pixels of one color in a region of a VNC server's screen.

A minimal RFB 3.8 client that asks for the region (X, Y, W, H) in raw
encoding, counts the pixels within TOLERANCE of RRGGBB on every channel, and
prints a JSON summary: {"x", "y", "w", "h", "color", "matches"}. With OUT, it
also writes the region as a PNG. It advertises the Cursor pseudo-encoding, so
the server sends the pointer separately instead of drawing it into the pixels.

Usage: rfb_color_probe.py HOST PORT X Y W H RRGGBB TOLERANCE [OUT.png]
"""

import json
import socket
import struct
import sys
import time
import zlib
from pathlib import Path

RAW = 0
RICH_CURSOR = -239
DESKTOP_SIZE = -223
READ_TIMEOUT_S = 10
MAX_WAIT_S = 15


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("server closed the connection")
        buf += chunk
    return bytes(buf)


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
    # 32bpp little-endian true color: each pixel arrives as B, G, R, X.
    pixel_format = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    sock.sendall(struct.pack(">B3x", 0) + pixel_format)
    encodings = [RAW, DESKTOP_SIZE, RICH_CURSOR]
    sock.sendall(
        struct.pack(">BxH", 2, len(encodings)) + b"".join(struct.pack(">i", e) for e in encodings)
    )
    return width, height


def read_region(sock: socket.socket, x: int, y: int, w: int, h: int) -> bytes:
    """Return the region as R, G, B bytes, row by row."""
    rgb = bytearray(w * h * 3)
    covered = bytearray(w * h)
    remaining = w * h
    deadline = time.monotonic() + MAX_WAIT_S
    sock.sendall(struct.pack(">BBHHHH", 3, 0, x, y, w, h))
    while remaining > 0:
        if time.monotonic() >= deadline:
            raise RuntimeError(f"region not fully received after {MAX_WAIT_S} s")
        (msg_type,) = struct.unpack("B", recv_exact(sock, 1))
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
            rx, ry, rw, rh, encoding = struct.unpack(">HHHHi", recv_exact(sock, 12))
            if encoding == DESKTOP_SIZE:
                continue
            if encoding == RICH_CURSOR:
                recv_exact(sock, rw * rh * 4 + (rw + 7) // 8 * rh)
                continue
            if encoding != RAW:
                raise RuntimeError(f"unexpected encoding {encoding}")
            pixels = recv_exact(sock, rw * rh * 4)
            for row in range(rh):
                py = ry + row - y
                if not 0 <= py < h:
                    continue
                for col in range(rw):
                    px = rx + col - x
                    if not 0 <= px < w:
                        continue
                    i = py * w + px
                    b, g, r = pixels[(row * rw + col) * 4 : (row * rw + col) * 4 + 3]
                    rgb[i * 3 : i * 3 + 3] = bytes((r, g, b))
                    if not covered[i]:
                        covered[i] = 1
                        remaining -= 1
        if remaining > 0:
            sock.sendall(struct.pack(">BBHHHH", 3, 0, x, y, w, h))
    return bytes(rgb)


def write_png(path: Path, w: int, h: int, rgb: bytes) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        )

    raw = b"".join(b"\x00" + rgb[row * w * 3 : (row + 1) * w * 3] for row in range(h))
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )


def main(argv: list[str]) -> int:
    if len(argv) not in (8, 9):
        print(__doc__, file=sys.stderr)
        return 2
    host, port = argv[0], int(argv[1])
    x, y, w, h = (int(v) for v in argv[2:6])
    color, tolerance = argv[6].lower(), int(argv[7])
    target = bytes.fromhex(color)
    with socket.create_connection((host, port), timeout=READ_TIMEOUT_S) as sock:
        width, height = handshake(sock)
        if w <= 0 or h <= 0 or x + w > width or y + h > height:
            raise RuntimeError(f"region {x},{y} {w}x{h} is outside the {width}x{height} screen")
        rgb = read_region(sock, x, y, w, h)
    matches = sum(
        1
        for i in range(0, len(rgb), 3)
        if all(abs(rgb[i + c] - target[c]) <= tolerance for c in range(3))
    )
    if len(argv) == 9:
        write_png(Path(argv[8]), w, h, rgb)
    print(json.dumps({"x": x, "y": y, "w": w, "h": h, "color": color, "matches": matches}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
