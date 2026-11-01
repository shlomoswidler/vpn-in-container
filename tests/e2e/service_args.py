#!/usr/bin/env python3
"""Turn the firefox service from `docker compose config --format json` (stdin)
into the image name (first line) and `docker run` arguments (one per line)
that reproduce its browser setup: the XCURSOR_*, display, WEB_AUDIO and FF_PREF_*
environment variables, and the read-only mounts under the cursor-related
directories, the Firefox profile (userChrome.css, customKeys.json), the
Firefox install directory (autoconfig) and the image's services (the shutdown
script, /etc/services.d/app/kill). It also carries the service's security
options, capabilities, read-only root and limits (tests/run_args.py), so the
test runs Firefox as hardened as the service.
"""

import importlib.util
import json
import sys
from pathlib import Path

RUN_ARGS = Path(__file__).resolve().parent.parent / "run_args.py"

ENV_KEYS = (
    "XCURSOR_THEME",
    "XCURSOR_SIZE",
    "DISPLAY_WIDTH",
    "DISPLAY_HEIGHT",
    "DARK_MODE",
    "WEB_AUDIO",
    "KEEP_APP_RUNNING",
)
FF_PREF_PREFIX = "FF_PREF_"
MOUNT_PREFIXES = (
    "/usr/share/icons/",
    "/opt/noVNC/",
    "/etc/cont-init.d/",
    "/etc/services.d/",
    "/config/profile/chrome/",
    "/config/profile/customKeys.json",
    "/usr/lib/firefox/",
)


def service_args(config: dict) -> list[str]:
    service = config["services"]["firefox"]
    lines = [service["image"]]
    environment = service.get("environment", {})
    for key in ENV_KEYS:
        if key in environment:
            lines += ["-e", f"{key}={environment[key]}"]
    for key in sorted(environment):
        if key.startswith(FF_PREF_PREFIX):
            lines += ["-e", f"{key}={environment[key]}"]
    for volume in service.get("volumes", []):
        if volume.get("read_only") and volume["target"].startswith(MOUNT_PREFIXES):
            lines += ["-v", f"{volume['source']}:{volume['target']}:ro"]
    return lines + hardening_args(service)


def load_hardening_args():
    # Loaded by path: tests/ is not on sys.path.
    spec = importlib.util.spec_from_file_location("run_args", RUN_ARGS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.hardening_args


hardening_args = load_hardening_args()


if __name__ == "__main__":
    print("\n".join(service_args(json.load(sys.stdin))))
