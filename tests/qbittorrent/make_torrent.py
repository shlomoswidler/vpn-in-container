#!/usr/bin/env python3
"""Write random multi-file content and a private, tracker-less .torrent for it.

Used by tests/qbittorrent/download.sh to check a real download between two
qBittorrent containers. File sizes are odd on purpose so pieces span file
boundaries and the last piece is partial.

Usage: make_torrent.py CONTENT_DIR TORRENT_FILE
Prints the v1 info hash, then one "SHA256  relative/path" line per file.
"""

import hashlib
import os
import sys
from pathlib import Path

NAME = "qbt-download-test"
PIECE_LENGTH = 65536
FILES = (
    ("a/first.bin", 1_048_583),
    ("a/second.bin", 300_007),
    ("b/third.bin", 2_500_001),
    ("tiny.txt", 13),
)


def bencode(value: object) -> bytes:
    if isinstance(value, int):
        return b"i%de" % value
    if isinstance(value, bytes):
        return b"%d:%s" % (len(value), value)
    if isinstance(value, str):
        return bencode(value.encode())
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        items = sorted(
            (key.encode() if isinstance(key, str) else key, item) for key, item in value.items()
        )
        return b"d" + b"".join(bencode(key) + bencode(item) for key, item in items) + b"e"
    raise TypeError(f"cannot bencode {type(value).__name__}")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    content_dir, torrent_file = Path(argv[0]) / NAME, Path(argv[1])
    stream = b""
    files = []
    digests = []
    for relative, size in FILES:
        data = os.urandom(size)
        path = content_dir / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        stream += data
        files.append({"length": size, "path": relative.split("/")})
        digests.append(f"{hashlib.sha256(data).hexdigest()}  {relative}")
    pieces = b"".join(
        hashlib.sha1(stream[i : i + PIECE_LENGTH]).digest()
        for i in range(0, len(stream), PIECE_LENGTH)
    )
    info = {
        "files": files,
        "name": NAME,
        "piece length": PIECE_LENGTH,
        "pieces": pieces,
        "private": 1,
    }
    torrent_file.write_bytes(bencode({"info": info}))
    print(hashlib.sha1(bencode(info)).hexdigest())
    print("\n".join(digests))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
