#!/usr/bin/env python3
"""Serve the files in DIRECTORY on 127.0.0.1:PORT for tests/e2e/run.sh, with
.torrent files as application/x-bittorrent, the type torrent sites send.

Usage: torrent_server.py PORT DIRECTORY
"""

import functools
import http.server
import sys
from typing import ClassVar


class TorrentHandler(http.server.SimpleHTTPRequestHandler):
    extensions_map: ClassVar[dict[str, str]] = {
        ".torrent": "application/x-bittorrent",
        ".html": "text/html",
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    handler = functools.partial(TorrentHandler, directory=argv[1])
    with http.server.ThreadingHTTPServer(("127.0.0.1", int(argv[0])), handler) as server:
        server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
