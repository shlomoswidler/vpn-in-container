#!/usr/bin/env python3
"""Write a tiny private, tracker-less .torrent file and print its info hash.

Used by tests/stack/run.sh to exercise the watch-folder hand-off: qBittorrent
must pick the file up and add the torrent. The torrent is private and has no
trackers, so adding it makes no network contact (no tracker, DHT or PEX).

Usage: torrent_file.py OUT_FILE NAME
"""

import hashlib
import sys
from pathlib import Path

PIECE_LENGTH = 16384


def bencode(value: object) -> bytes:
    if isinstance(value, int):
        return b"i%de" % value
    if isinstance(value, bytes):
        return b"%d:%s" % (len(value), value)
    if isinstance(value, str):
        return bencode(value.encode())
    if isinstance(value, dict):
        items = sorted(
            (key.encode() if isinstance(key, str) else key, item) for key, item in value.items()
        )
        return b"d" + b"".join(bencode(key) + bencode(item) for key, item in items) + b"e"
    raise TypeError(f"cannot bencode {type(value).__name__}")


def torrent(name: str) -> tuple[bytes, str]:
    """Return the .torrent bytes and the v1 info hash (hex) for NAME."""
    content = f"vpn-in-container stack test: {name}\n".encode()
    info = {
        "length": len(content),
        "name": f"{name}.txt",
        "piece length": PIECE_LENGTH,
        "pieces": hashlib.sha1(content).digest(),
        "private": 1,
    }
    return bencode({"info": info}), hashlib.sha1(bencode(info)).hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    data, info_hash = torrent(argv[1])
    Path(argv[0]).write_bytes(data)
    print(info_hash)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
