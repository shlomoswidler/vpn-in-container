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
import tempfile
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
# The services the hardening options apply to. Autoheal is left out: its image is to be
# replaced by a hardened local build.
HARDENED = (VPN, *BEHIND_VPN, AUTOHEAL_PROXY)
NO_NEW_PRIVILEGES = "no-new-privileges:true"
# Every hardened service's logging: json-file, rotated at 10 MB, three files kept.
LOGGING = {"driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}}
# Each hardened service drops every capability and adds back only these, the set its image
# was measured to need (docker-compose.yml says what each is for).
CAPABILITIES = {
    VPN: {"NET_ADMIN", "NET_RAW", "CHOWN", "DAC_OVERRIDE"},
    "firefox": {"CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID", "KILL", "NET_BIND_SERVICE"},
    "qbittorrent": {"CHOWN", "DAC_OVERRIDE", "SETUID", "SETGID", "KILL"},
    "qsticky": set(),
    AUTOHEAL_PROXY: set(),
}


def compose_config(env_file: Path = ENV_FILE, **variables: str | None) -> dict:
    """Return the resolved Compose model; raise AssertionError if it cannot be read.

    VARIABLES set (or, with None, remove) variables of the environment Compose runs in.
    """
    env = {**os.environ, "PUID": str(os.getuid()), "PGID": str(os.getgid())}
    for name, value in variables.items():
        if value is None:
            env.pop(name, None)
        else:
            env[name] = value
    command = [
        "docker", "compose", "-f", str(COMPOSE_FILE), "--env-file", str(env_file),
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


class DownloadsPathTests(unittest.TestCase):
    """One default for DOWNLOADS_PATH: the compose file's, which .env.example documents."""

    DEFAULT = Path(os.environ["HOME"]) / "Downloads" / "vpn-in-container"
    # The example line in .env.example, commented out so the compose default applies.
    EXAMPLE = "# DOWNLOADS_PATH=${HOME}/Downloads/vpn-in-container"

    def mounts(self, env_file: Path, **variables: str | None) -> dict[str, str]:
        services = compose_config(env_file, **variables)["services"]
        found = {}
        for name, target in (
            ("qbittorrent", "/downloads"),
            ("qbittorrent", "/watch"),
            ("firefox", "/config/downloads"),
        ):
            sources = [v["source"] for v in services[name]["volumes"] if v["target"] == target]
            found[target] = sources[0] if sources else ""
        return found

    def expected(self, root: Path) -> dict[str, str]:
        return {
            "/downloads": str(root),
            "/watch": str(root / "downloads"),
            "/config/downloads": str(root / "downloads"),
        }

    def test_env_example_yields_the_default(self):
        self.assertEqual(self.mounts(ENV_FILE, DOWNLOADS_PATH=None), self.expected(self.DEFAULT))

    def test_the_documented_example_line_is_the_default(self):
        lines = ENV_FILE.read_text().splitlines()
        self.assertIn(self.EXAMPLE, lines)
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / ".env"
            # Uncommented, it gives the same path: ${HOME} is interpolated in .env files.
            env_file.write_text(self.EXAMPLE.removeprefix("# ") + "\n")
            self.assertEqual(
                self.mounts(env_file, DOWNLOADS_PATH=None), self.expected(self.DEFAULT)
            )
            env_file.write_text("DOWNLOADS_PATH=/srv/torrents\n")
            self.assertEqual(
                self.mounts(env_file, DOWNLOADS_PATH=None), self.expected(Path("/srv/torrents"))
            )


class QstickyPasswordTests(unittest.TestCase):
    """QBITTORRENT_PASS is only what qSticky sends when it logs in: optional, no default."""

    def password(self, env_file: Path, **variables: str | None) -> str | None:
        config = compose_config(env_file, **variables)
        return config["services"]["qsticky"].get("environment", {}).get("QBITTORRENT_PASS")

    def test_env_example_sets_no_password(self):
        self.assertEqual(self.password(ENV_FILE, QBITTORRENT_PASS=None), "")

    def test_unset_means_empty_not_a_made_up_default(self):
        # The old fallback, adminadmin, has not been qBittorrent's default since 4.6.1.
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / ".env"
            env_file.write_text("COMPOSE_PROJECT_NAME=vpn-in-container\n")
            self.assertEqual(self.password(env_file, QBITTORRENT_PASS=None), "")
            env_file.write_text("QBITTORRENT_PASS=from-env-file\n")
            self.assertEqual(self.password(env_file, QBITTORRENT_PASS=None), "from-env-file")
            self.assertEqual(self.password(env_file, QBITTORRENT_PASS="from-shell"), "from-shell")


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

    def test_every_service_uses_unless_stopped(self):
        # One policy: with `always` on some services, `docker compose stop` and a reboot (or a
        # Docker restart) bring only those back, the VPN without the services behind it.
        for name, service in self.services.items():
            with self.subTest(service=name):
                self.assertEqual(service.get("restart"), "unless-stopped")

    def test_qsticky_reaches_qbittorrent_over_loopback(self):
        # qBittorrent skips authentication for loopback clients (LocalHostAuth=false, set by
        # the init script), which is why qSticky's password is not checked; see below.
        environment = self.services["qsticky"].get("environment", {})
        self.assertEqual(environment.get("QBITTORRENT_HOST"), "localhost")
        self.assertEqual(self.services["qsticky"].get("network_mode"), f"service:{VPN}")

    def test_hardened_services_cannot_gain_privileges(self):
        # no-new-privileges: no setuid, setgid or file-capability binary can raise the
        # privileges of a process (the images' init drops them with syscalls instead).
        for name in HARDENED:
            with self.subTest(service=name):
                self.assertIn(NO_NEW_PRIVILEGES, self.services[name].get("security_opt", []))

    def test_hardened_services_drop_every_capability_they_do_not_need(self):
        self.assertEqual(set(CAPABILITIES), set(HARDENED))
        for name, needed in CAPABILITIES.items():
            with self.subTest(service=name):
                service = self.services[name]
                self.assertEqual(service.get("cap_drop"), ["ALL"])
                added = service.get("cap_add", [])
                self.assertEqual(len(added), len(set(added)), f"duplicates in {added}")
                self.assertEqual(set(added), needed)

    def test_hardened_services_have_pid_and_memory_limits(self):
        for name in HARDENED:
            with self.subTest(service=name):
                service = self.services[name]
                self.assertGreater(service.get("pids_limit", 0), 0, "no pids_limit")
                self.assertGreater(int(service.get("mem_limit", 0)), 0, "no mem_limit")

    def test_firefox_memory_limit_leaves_room_beyond_its_shared_memory(self):
        # /dev/shm is a tmpfs: what Firefox keeps there counts against the memory limit.
        firefox = self.services["firefox"]
        self.assertGreaterEqual(
            int(firefox.get("mem_limit", 0)), 3 * int(firefox.get("shm_size", 0))
        )

    def test_hardened_services_rotate_their_logs(self):
        # Explicit, not the daemon's default: a stock Docker Engine keeps json-file logs
        # without limit. One definition (x-logging) for all.
        for name in HARDENED:
            with self.subTest(service=name):
                self.assertEqual(self.services[name].get("logging"), LOGGING)

    def test_firefox_cursor_size_matches_the_theme(self):
        size = self.services["firefox"].get("environment", {}).get("XCURSOR_SIZE")
        self.assertEqual(size, str(generator_nominal_size()))


if __name__ == "__main__":
    unittest.main()
