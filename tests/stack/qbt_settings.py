#!/usr/bin/env python3
"""Check qBittorrent preferences (JSON on stdin) against what the stack expects.

The expected values are what config/qbittorrent-init.d/10-configure-qbittorrent.sh
sets, plus the /watch folder for the .torrent hand-off from Firefox. Prints one
line describing every mismatch, or nothing when all match.
"""

import json
import sys


def problems(prefs: dict) -> list[str]:
    found = []
    if prefs.get("save_path", "").rstrip("/") != "/downloads":
        found.append(f"save_path={prefs.get('save_path')}")
    if prefs.get("temp_path", "").rstrip("/") != "/downloads/incomplete":
        found.append(f"temp_path={prefs.get('temp_path')}")
    if not prefs.get("temp_path_enabled"):
        found.append("temp_path_enabled=false")
    if "/watch" not in prefs.get("scan_dirs", {}):
        found.append(f"scan_dirs={prefs.get('scan_dirs')}")
    if prefs.get("upnp"):
        found.append("upnp=true")
    if not prefs.get("bypass_auth_subnet_whitelist_enabled"):
        found.append("bypass_auth_subnet_whitelist_enabled=false")
    return found


if __name__ == "__main__":
    print("; ".join(problems(json.load(sys.stdin))))
