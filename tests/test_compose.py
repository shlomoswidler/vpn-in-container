"""Static tests of docker-compose.yml: image pins, Autoheal scoping, network isolation.

Reads the resolved model from `docker compose config --format json`, with .env.example as
the env file (so a local .env does not change the result) and PUID/PGID set to the current
user (.env.example leaves them empty, and the file requires them). Needs the docker CLI with
the Compose plugin, but no running daemon or containers.
Run: python3 -m unittest discover -s tests
"""

import importlib.util
import json
import os
import re
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
COMPOSE_FILE = REPO_ROOT / "docker-compose.yml"
ENV_FILE = REPO_ROOT / ".env.example"
GENERATOR = REPO_ROOT / "config" / "cursors" / "generate_native_theme.py"

# name:tag@sha256:<digest>. The name may include a registry host and port; the tag is the
# part after the last colon of the reference, so it contains no slash.
PINNED_IMAGE = re.compile(r"^[^@\s]+:[\w][\w.-]{0,127}@sha256:[0-9a-f]{64}$")
DOCKER_SOCKET = "/var/run/docker.sock"
AUTOHEAL = "autoheal"
VPN = "vpn"
BEHIND_VPN = ("firefox", "qbittorrent", "qsticky")


def compose_config() -> dict:
    """Return the resolved Compose model; raise AssertionError if it cannot be read."""
    env = {**os.environ, "PUID": str(os.getuid()), "PGID": str(os.getgid())}
    command = [
        "docker", "compose", "-f", str(COMPOSE_FILE), "--env-file", str(ENV_FILE),
        "config", "--format", "json",
    ]  # fmt: skip
    try:
        result = subprocess.run(
            command, cwd=REPO_ROOT, env=env, capture_output=True, text=True, timeout=60,
            check=False,
        )  # fmt: skip
    except FileNotFoundError as err:
        raise AssertionError(
            f"these tests need the docker CLI with the Compose plugin: {err}"
        ) from err
    if result.returncode != 0:
        raise AssertionError(
            f"`{' '.join(command)}` failed (exit {result.returncode}); these tests need the "
            f"docker CLI with the Compose plugin:\n{result.stderr}"
        )
    return json.loads(result.stdout)


def generator_nominal_size() -> int:
    spec = importlib.util.spec_from_file_location("generate_native_theme", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.NOMINAL_SIZE


class ComposeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.services = compose_config()["services"]

    def test_expected_services_exist(self):
        # The other tests look services up by name; a rename must fail here, not pass vacuously.
        self.assertEqual(set(self.services), {VPN, AUTOHEAL, *BEHIND_VPN})

    def test_every_image_is_pinned_by_tag_and_digest(self):
        for name, service in self.services.items():
            with self.subTest(service=name):
                self.assertRegex(service.get("image", ""), PINNED_IMAGE)

    def test_every_service_but_autoheal_has_the_autoheal_label(self):
        for name, service in self.services.items():
            if name == AUTOHEAL:
                continue
            with self.subTest(service=name):
                self.assertEqual(service.get("labels", {}).get(AUTOHEAL), "true")

    def test_autoheal_is_scoped_to_the_label(self):
        environment = self.services[AUTOHEAL].get("environment", {})
        label = environment.get("AUTOHEAL_CONTAINER_LABEL")
        self.assertTrue(label, "AUTOHEAL_CONTAINER_LABEL must be set")
        self.assertNotEqual(label, "all", "`all` would heal every container on the host")
        # Autoheal watches containers labeled <AUTOHEAL_CONTAINER_LABEL>=true.
        self.assertEqual(label, AUTOHEAL)

    def test_services_behind_the_vpn_share_its_network_and_publish_nothing(self):
        for name in BEHIND_VPN:
            with self.subTest(service=name):
                service = self.services[name]
                self.assertEqual(service.get("network_mode"), f"service:{VPN}")
                self.assertFalse(service.get("ports"), "publishes ports")

    def test_only_the_vpn_publishes_ports(self):
        publishing = {name for name, service in self.services.items() if service.get("ports")}
        self.assertEqual(publishing, {VPN})

    def test_the_docker_socket_mount_is_read_only(self):
        mounts = [
            (name, volume)
            for name, service in self.services.items()
            for volume in service.get("volumes", [])
            if DOCKER_SOCKET in (volume.get("source"), volume.get("target"))
        ]
        self.assertTrue(mounts, f"no service mounts {DOCKER_SOCKET}")
        for name, volume in mounts:
            with self.subTest(service=name):
                self.assertIs(volume.get("read_only"), True)

    def test_firefox_cursor_size_matches_the_theme(self):
        size = self.services["firefox"].get("environment", {}).get("XCURSOR_SIZE")
        self.assertEqual(size, str(generator_nominal_size()))


if __name__ == "__main__":
    unittest.main()
