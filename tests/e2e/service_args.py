#!/usr/bin/env python3
"""Turn the firefox service from `docker compose config --format json` (stdin)
into the image name (first line) and `docker run` arguments (one per line)
that reproduce its browser setup: the XCURSOR_*, display and FF_PREF_*
environment variables, and the read-only mounts under the cursor-related
directories and the Firefox profile's chrome/ folder (userChrome.css).
"""

import json
import sys

ENV_KEYS = ("XCURSOR_THEME", "XCURSOR_SIZE", "DISPLAY_WIDTH", "DISPLAY_HEIGHT", "DARK_MODE")
FF_PREF_PREFIX = "FF_PREF_"
MOUNT_PREFIXES = (
    "/usr/share/icons/",
    "/opt/noVNC/",
    "/etc/cont-init.d/",
    "/config/profile/chrome/",
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
    return lines


if __name__ == "__main__":
    print("\n".join(service_args(json.load(sys.stdin))))
