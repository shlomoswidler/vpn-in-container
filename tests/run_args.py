#!/usr/bin/env python3
"""Print the `docker run` arguments (one per line) for a service's security options.

Reads `docker compose config --format json` on stdin; the service name is the argument.
The tests that start a service's image in a throwaway container (tests/e2e/run.sh through
service_args.py, tests/qbittorrent/fresh-install.sh) pass these on, so the image runs as
hardened as the service: security_opt, capabilities, a read-only root with its tmpfs
mounts, and the PID and memory limits.

Usage: docker compose config --format json | python3 -I tests/run_args.py SERVICE
"""

import json
import sys


def hardening_args(service: dict) -> list[str]:
    """The `docker run` arguments for SERVICE's (a resolved Compose service) hardening."""
    args = []
    for option in service.get("security_opt", []):
        args += ["--security-opt", option]
    for capability in service.get("cap_drop", []):
        args += ["--cap-drop", capability]
    for capability in service.get("cap_add", []):
        args += ["--cap-add", capability]
    if service.get("read_only"):
        args.append("--read-only")
    for target in service.get("tmpfs", []):
        args += ["--tmpfs", target]
    if "pids_limit" in service:
        args += ["--pids-limit", str(service["pids_limit"])]
    if "mem_limit" in service:
        # Compose resolves it to bytes.
        args += ["--memory", str(service["mem_limit"])]
    return args


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} SERVICE < compose.json")
    services = json.load(sys.stdin)["services"]
    if sys.argv[1] not in services:
        sys.exit(f"no service {sys.argv[1]!r} in the Compose model")
    print("\n".join(hardening_args(services[sys.argv[1]])))
