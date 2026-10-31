"""Static tests of docker-compose.yml: image pins, Autoheal scoping, network isolation.

Also checks config/autoheal-proxy/haproxy.cfg, the Docker API allowlist Autoheal goes through.

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
PROXY_TEMPLATE = REPO_ROOT / "config" / "autoheal-proxy" / "haproxy.cfg"

# name:tag@sha256:<digest>. The name may include a registry host and port; the tag is the
# part after the last colon of the reference, so it contains no slash.
PINNED_IMAGE = re.compile(r"^[^@\s]+:[\w][\w.-]{0,127}@sha256:[0-9a-f]{64}$")
DOCKER_SOCKET = "/var/run/docker.sock"
LOOPBACK = "127.0.0.1"
AUTOHEAL = "autoheal"
AUTOHEAL_PROXY = "autoheal-proxy"
AUTOHEAL_NETWORK = "autoheal-docker"
# Where the linuxserver/socket-proxy entrypoint reads its HAProxy template.
PROXY_TEMPLATE_TARGET = "/templates/haproxy.cfg"
# Every http-request rule of the proxy's frontend, in order: what Autoheal needs, then deny.
PROXY_RULES = [
    "http-request allow if METH_GET { path -m reg ^(/v[0-9.]+)?/_ping$ }",
    "http-request allow if METH_GET { path -m reg ^(/v[0-9.]+)?/containers/json$ }",
    "http-request allow if METH_POST { path -m reg ^(/v[0-9.]+)?/containers/[0-9a-f]{64}/restart$ }",
    "http-request deny",
]
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


def run_compose_config(env_file: Path, env: dict[str, str]) -> subprocess.CompletedProcess:
    """Run `docker compose config --quiet` with ENV_FILE and exactly ENV."""
    command = [
        "docker", "compose", "-f", str(COMPOSE_FILE), "--env-file", str(env_file),
        "config", "--quiet",
    ]  # fmt: skip
    return subprocess.run(
        command, cwd=REPO_ROOT, env=env, capture_output=True, text=True, timeout=60, check=False
    )


class EnvExampleTests(unittest.TestCase):
    """An unedited copy of .env.example must fail loudly where it needs the user's values."""

    def setUp(self):
        # The environment without the variables .env.example is meant to supply.
        self.env = {
            k: v for k, v in os.environ.items() if k not in ("PUID", "PGID", "DOWNLOADS_PATH")
        }

    def test_puid_and_pgid_guards_fire_when_unset(self):
        result = run_compose_config(ENV_FILE, self.env)
        self.assertNotEqual(result.returncode, 0, "config passed with PUID and PGID unset")
        self.assertIn("required variable PUID is missing a value: Set PUID in .env", result.stderr)
        self.assertIn("required variable PGID is missing a value: Set PGID in .env", result.stderr)

    def test_no_value_carries_an_inline_comment(self):
        # Compose strips leading spaces from an unquoted value and then removes only a comment
        # preceded by a space, so `PUID=   # Run: id -u` sets PUID to "# Run: id -u". Comments
        # belong on their own lines.
        for number, line in enumerate(ENV_FILE.read_text().splitlines(), 1):
            if "=" in line and not line.lstrip().startswith("#"):
                with self.subTest(line=number):
                    self.assertNotIn("#", line.split("=", 1)[1], line)


class ComposeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = compose_config()
        cls.services = cls.config["services"]

    def test_expected_services_exist(self):
        # The other tests look services up by name; a rename must fail here, not pass vacuously.
        self.assertEqual(set(self.services), {VPN, AUTOHEAL, AUTOHEAL_PROXY, *BEHIND_VPN})

    def test_every_image_is_pinned_by_tag_and_digest(self):
        for name, service in self.services.items():
            with self.subTest(service=name):
                self.assertRegex(service.get("image", ""), PINNED_IMAGE)

    def test_every_service_but_autoheal_and_its_proxy_has_the_autoheal_label(self):
        for name, service in self.services.items():
            with self.subTest(service=name):
                label = service.get("labels", {}).get(AUTOHEAL)
                if name in (AUTOHEAL, AUTOHEAL_PROXY):
                    # Autoheal restarts through the proxy: it cannot heal either of them.
                    self.assertIsNone(label)
                else:
                    self.assertEqual(label, "true")

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

    def test_published_ports_are_bound_to_loopback(self):
        # The web UIs have no password: without a host IP, Docker binds every interface and
        # OrbStack forwards the ports to the LAN.
        ports = [
            (name, port)
            for name, service in self.services.items()
            for port in service.get("ports", [])
        ]
        self.assertTrue(ports, "no service publishes a port")
        for name, port in ports:
            with self.subTest(service=name, port=port.get("published")):
                self.assertEqual(port.get("host_ip"), LOOPBACK)

    def test_only_the_proxy_mounts_the_docker_socket_read_only(self):
        mounts = [
            (name, volume)
            for name, service in self.services.items()
            for volume in service.get("volumes", [])
            if DOCKER_SOCKET in (volume.get("source"), volume.get("target"))
        ]
        self.assertEqual([name for name, _ in mounts], [AUTOHEAL_PROXY])
        # Read-only stops writes to the socket file, not API calls through it: the
        # allowlist in haproxy.cfg is what limits them.
        self.assertIs(mounts[0][1].get("read_only"), True)

    def test_autoheal_reaches_docker_only_through_the_proxy(self):
        autoheal = self.services[AUTOHEAL]
        mounts = [volume.get("target") for volume in autoheal.get("volumes", [])]
        self.assertNotIn(DOCKER_SOCKET, mounts)
        self.assertEqual(
            autoheal.get("environment", {}).get("DOCKER_SOCK"), f"tcp://{AUTOHEAL_PROXY}:2375"
        )
        self.assertNotIn("network_mode", autoheal)
        self.assertEqual(set(autoheal.get("networks", {})), {AUTOHEAL_NETWORK})
        condition = autoheal.get("depends_on", {}).get(AUTOHEAL_PROXY, {}).get("condition")
        self.assertEqual(condition, "service_healthy")

    def test_the_autoheal_network_is_internal_and_only_autoheal_and_its_proxy_use_it(self):
        self.assertIs(
            self.config.get("networks", {}).get(AUTOHEAL_NETWORK, {}).get("internal"), True
        )
        members = {
            name for name, s in self.services.items() if AUTOHEAL_NETWORK in s.get("networks", {})
        }
        self.assertEqual(members, {AUTOHEAL, AUTOHEAL_PROXY})
        self.assertEqual(set(self.services[AUTOHEAL_PROXY].get("networks", {})), {AUTOHEAL_NETWORK})

    def test_the_proxy_is_pinned_hardened_and_uses_the_allowlist(self):
        proxy = self.services[AUTOHEAL_PROXY]
        self.assertRegex(proxy.get("image", ""), PINNED_IMAGE)
        self.assertTrue(proxy["image"].startswith("lscr.io/linuxserver/socket-proxy:"))
        self.assertIs(proxy.get("read_only"), True)
        self.assertIn("/run", proxy.get("tmpfs", []))
        self.assertEqual(proxy.get("cap_drop"), ["ALL"])
        self.assertIn("no-new-privileges:true", proxy.get("security_opt", []))
        self.assertTrue(proxy.get("healthcheck", {}).get("test"), "no healthcheck")
        self.assertFalse(proxy.get("ports"), "publishes ports")
        template = [v for v in proxy.get("volumes", []) if v.get("target") == PROXY_TEMPLATE_TARGET]
        self.assertEqual([v.get("source") for v in template], [str(PROXY_TEMPLATE)])
        self.assertIs(template[0].get("read_only"), True)
        # The allowlist is the template's only filter: env flags such as CONTAINERS=1 or
        # ALLOW_RESTARTS=1 would only matter for the image's own template.
        flags = set(proxy.get("environment", {})) - {"LOG_LEVEL", "TZ"}
        self.assertEqual(flags, set(), "env flags the template ignores")

    def test_the_proxy_template_allows_only_what_autoheal_needs(self):
        rules = [
            line.strip()
            for line in PROXY_TEMPLATE.read_text().splitlines()
            if line.strip().startswith("http-request")
        ]
        self.assertEqual(rules, PROXY_RULES)

    def test_firefox_cursor_size_matches_the_theme(self):
        size = self.services["firefox"].get("environment", {}).get("XCURSOR_SIZE")
        self.assertEqual(size, str(generator_nominal_size()))


if __name__ == "__main__":
    unittest.main()
