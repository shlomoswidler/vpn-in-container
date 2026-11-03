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
import tomllib
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
COMPOSE_FILE = REPO_ROOT / "docker-compose.yml"
ENV_FILE = REPO_ROOT / ".env.example"
GENERATOR = REPO_ROOT / "config" / "cursors" / "generate_native_theme.py"
IMAGE_OVERLAYS = REPO_ROOT / "tests" / "image_overlays.py"
SERVICE_ARGS = REPO_ROOT / "tests" / "e2e" / "service_args.py"
PROXY_TEMPLATE = REPO_ROOT / "config" / "autoheal-proxy" / "haproxy.cfg"

# name:tag@sha256:<digest>. The name may include a registry host and port; the tag is the
# part after the last colon of the reference, so it contains no slash.
PINNED_IMAGE = re.compile(r"^([^@\s]+):([\w][\w.-]{0,127})@sha256:([0-9a-f]{64})$")
# A service built here instead: a GitHub repository at a full commit SHA (BuildKit fetches
# exactly that commit), and a Dockerfile in the compose file whose every FROM is pinned.
GIT_CONTEXT = re.compile(r"^https://github\.com/[\w.-]+/([\w.-]+)\.git#([0-9a-f]{40})$")
# Only these build options: any other (args, target, a Dockerfile from the context, extra
# contexts, ...) could change what is built without changing the inputs checked here.
BUILD_KEYS = {"context", "dockerfile_inline", "labels"}
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
# The services the hardening options apply to: every one.
HARDENED = (VPN, *BEHIND_VPN, AUTOHEAL, AUTOHEAL_PROXY)
# Autoheal runs as nobody (it needs no file and no privilege).
NOBODY = "65534:65534"
NO_NEW_PRIVILEGES = "no-new-privileges:true"
# The services with a read-only root filesystem, and the tmpfs mounts each needs. Gluetun
# writes /etc at start (its user, resolv.conf); in read-only mode the qBittorrent image
# ignores PUID/PGID and runs as 911:1001 (see docker-compose.yml).
READ_ONLY_TMPFS = {
    "firefox": {"/tmp", "/run"},
    "qsticky": {"/app/health"},
    AUTOHEAL: set(),
    AUTOHEAL_PROXY: {"/run"},
}
# Firefox preferences the firefox service must set through FF_PREF_* entries
# (<pref name>=<value>; tests/e2e/run.sh checks that each reaches prefs.js).
FIREFOX_PREFS = {
    # WebRTC: gather only on the default route's interface, and offer no host candidate.
    "media.peerconnection.ice.default_address_only=true",
    "media.peerconnection.ice.no_host=true",
    # Closing the last tab leaves the window (closing it would stop the container).
    "browser.tabs.closeWindowWithLastTab=false",
}
# Every hardened service's logging: json-file, rotated at 10 MB, three files kept.
LOGGING = {"driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}}
# Each hardened service drops every capability and adds back only these, the set its image
# was measured to need (docker-compose.yml says what each is for).
CAPABILITIES = {
    VPN: {"NET_ADMIN", "NET_RAW"},
    "firefox": {"CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID", "KILL", "NET_BIND_SERVICE"},
    "qbittorrent": {"CHOWN", "DAC_OVERRIDE", "SETUID", "SETGID", "KILL"},
    "qsticky": set(),
    AUTOHEAL: set(),
    AUTOHEAL_PROXY: set(),
}
# Where Gluetun keeps its status files (the forwarded port, the public IP), and the variables
# that would move them: their defaults are in this directory.
GLUETUN_STATUS_DIR = "/tmp/gluetun"
GLUETUN_STATUS_FILE_VARIABLES = (
    "VPN_PORT_FORWARDING_STATUS_FILE",
    "PORT_FORWARDING_STATUS_FILE",
    "PRIVATE_INTERNET_ACCESS_VPN_PORT_FORWARDING_STATUS_FILE",
    "PUBLICIP_FILE",
    "IP_STATUS_FILE",
)
# Gluetun's control-server roles: one, qSticky's, rendered by Compose from GLUETUN_API_KEY
# (configs: gluetun_auth), and the only routes it may call.
GLUETUN_AUTH_CONFIG = "gluetun_auth"
QSTICKY_ROUTES = ["GET /v1/portforward", "GET /v1/vpn/status"]
GLUETUN_API_KEY_GUARD = (
    "required variable GLUETUN_API_KEY is missing a value: Set GLUETUN_API_KEY in .env"
)
# How much longer than the longest stop timeout Autoheal's curl must wait for a restart's
# answer: the restart also starts the container again.
RESTART_MARGIN = 30


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


def dockerfile_from_lines(dockerfile: str) -> list[str]:
    """The image reference of each FROM instruction (without `AS <stage>`)."""
    return [
        line.split()[1] if len(line.split()) > 1 else ""
        for line in dockerfile.splitlines()
        if line.split()[:1] and line.split()[0].upper() == "FROM"
    ]


def build_pin_problems(service: dict) -> list[str]:
    """Why SERVICE (resolved, with a build section) is not pinned; [] if it is.

    Pinned means: built from a GitHub repository at a full commit SHA, with a
    dockerfile_inline whose every FROM is name:tag@sha256:<digest> (and no `# syntax`
    line, which would fetch a BuildKit frontend); never pulled; an image tag that names
    the commit and the base, so that changing either builds a new image instead of reusing
    the old one; and labels that record both (tests/stack/run.sh compares them with the
    running image's).
    """
    build = service.get("build", {})
    problems = []
    if set(build) - BUILD_KEYS:
        problems.append(f"build options beyond {sorted(BUILD_KEYS)}: {sorted(set(build))}")
    context = GIT_CONTEXT.match(build.get("context", ""))
    if not context:
        problems.append(f"context is not a GitHub repository at a full commit SHA: {build}")
    dockerfile = build.get("dockerfile_inline", "")
    froms = dockerfile_from_lines(dockerfile)
    if not froms:
        problems.append("no dockerfile_inline with a FROM line")
    bases = [PINNED_IMAGE.match(ref) for ref in froms]
    problems += [
        f"FROM {ref} is not name:tag@sha256:<digest>" for ref, m in zip(froms, bases) if not m
    ]
    if re.search(r"^\s*#\s*syntax\s*=", dockerfile, re.MULTILINE | re.IGNORECASE):
        problems.append("a `# syntax` line fetches a BuildKit frontend")
    if service.get("pull_policy") != "never":
        problems.append(f"pull_policy is {service.get('pull_policy')!r}, not 'never'")
    if problems:
        return problems
    commit = context.group(2)
    name, tag, digest = bases[-1].groups()
    base = f"{name.rsplit('/', 1)[-1]}{tag}"
    image_tag = service.get("image", "").rpartition(":")[2]
    want_tag = f"{commit[:7]}-{base}-{digest[:12]}"
    if image_tag != want_tag:
        problems.append(f"image tag {image_tag!r} does not name the build inputs ({want_tag!r})")
    labels = build.get("labels", {})
    want_labels = {
        "org.opencontainers.image.revision": commit,
        "org.opencontainers.image.base.name": f"{name}:{tag}",
        "org.opencontainers.image.base.digest": f"sha256:{digest}",
    }
    for key, value in want_labels.items():
        if labels.get(key) != value:
            problems.append(f"label {key} is {labels.get(key)!r}, not {value!r}")
    return problems


def proxy_server_timeout_seconds() -> int:
    """HAProxy's `timeout server` in config/autoheal-proxy/haproxy.cfg, in seconds."""
    # HAProxy's time units; a bare number is in milliseconds.
    units = {"us": 1e-6, "ms": 1e-3, "": 1e-3, "s": 1, "m": 60, "h": 3600, "d": 86400}
    line = re.compile(r"^\s*timeout server\s+(\d+)(us|ms|s|m|h|d|)\s*$", re.MULTILINE)
    found = line.findall(PROXY_TEMPLATE.read_text())
    if len(found) != 1:
        raise AssertionError(f"want one `timeout server` line in {PROXY_TEMPLATE}: {found}")
    value, unit = found[0]
    return int(int(value) * units[unit])


def generator_nominal_size() -> int:
    spec = importlib.util.spec_from_file_location("generate_native_theme", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.NOMINAL_SIZE


def load_image_overlays():
    """tests/image_overlays.py, loaded by path (tests/ is not on sys.path)."""
    spec = importlib.util.spec_from_file_location("image_overlays", IMAGE_OVERLAYS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def image_overlays() -> tuple:
    """The patched image files tests/image_overlays.py checks against the image's."""
    return load_image_overlays().OVERLAYS


def image_overlay_additions() -> tuple:
    """The files of the repo's own tests/image_overlays.py checks the image's directories for."""
    return load_image_overlays().ADDITIONS


def e2e_service_args(config: dict) -> list[str]:
    """The `docker run` arguments the browser and e2e tests start Firefox with, for CONFIG."""
    spec = importlib.util.spec_from_file_location("service_args", SERVICE_ARGS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.service_args(config)


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

    def test_gluetun_api_key_guard_fires_when_empty_or_unset(self):
        # Without it, Compose would render an auth file with an empty key, and qSticky would
        # send one.
        env = {**self.env, "PUID": str(os.getuid()), "PGID": str(os.getgid())}
        result = run_compose_config(ENV_FILE, {**env, "GLUETUN_API_KEY": ""})
        self.assertNotEqual(result.returncode, 0, "config passed with GLUETUN_API_KEY empty")
        self.assertIn(GLUETUN_API_KEY_GUARD, result.stderr)
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / ".env"
            env_file.write_text("COMPOSE_PROJECT_NAME=vpn-in-container\n")
            env.pop("GLUETUN_API_KEY", None)
            result = run_compose_config(env_file, env)
        self.assertNotEqual(result.returncode, 0, "config passed with GLUETUN_API_KEY unset")
        self.assertIn(GLUETUN_API_KEY_GUARD, result.stderr)

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
        # The env files below set only what is tested; the compose file requires a key.
        variables = {"GLUETUN_API_KEY": "test-key", **variables}
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
        # The env files below set only what is tested; the compose file requires a key.
        variables = {"GLUETUN_API_KEY": "test-key", **variables}
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


class PrivateBrowsingTests(unittest.TestCase):
    """FIREFOX_PRIVATE_BROWSING=true turns on permanent private browsing; else Firefox's default.

    The firefox service always passes the pref, false included: without an entry the image
    leaves the last line it wrote in prefs.js, so a profile that once had true would stay
    private (measured). Any other value reaches the container unchanged, where
    config/firefox-init.d/54-firefox-private-browsing.sh refuses it.
    """

    PREF = "browser.privatebrowsing.autostart"
    # The example line in .env.example, commented out so the default (off) applies.
    EXAMPLE = "# FIREFOX_PRIVATE_BROWSING=true"
    INIT_SCRIPT = REPO_ROOT / "config" / "firefox-init.d" / "54-firefox-private-browsing.sh"

    def entry(self, env_file: Path, **variables: str | None) -> str | None:
        # The env files below set only what is tested; the compose file requires a key.
        variables = {"GLUETUN_API_KEY": "test-key", **variables}
        firefox = compose_config(env_file, **variables)["services"]["firefox"]
        return firefox.get("environment", {}).get("FF_PREF_PRIVATE_BROWSING")

    def entry_from(self, *lines: str, **variables: str | None) -> str | None:
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / ".env"
            env_file.write_text("".join(f"{line}\n" for line in lines))
            return self.entry(env_file, **variables)

    def test_env_example_leaves_it_off(self):
        self.assertEqual(self.entry(ENV_FILE, FIREFOX_PRIVATE_BROWSING=None), f"{self.PREF}=false")

    def test_unset_or_empty_is_off(self):
        for lines in (("COMPOSE_PROJECT_NAME=vpn-in-container",), ("FIREFOX_PRIVATE_BROWSING=",)):
            with self.subTest(lines=lines):
                self.assertEqual(
                    self.entry_from(*lines, FIREFOX_PRIVATE_BROWSING=None), f"{self.PREF}=false"
                )

    def test_the_documented_example_line_turns_it_on(self):
        self.assertIn(self.EXAMPLE, ENV_FILE.read_text().splitlines())
        uncommented = self.EXAMPLE.removeprefix("# ")
        self.assertEqual(
            self.entry_from(uncommented, FIREFOX_PRIVATE_BROWSING=None), f"{self.PREF}=true"
        )

    def test_false_and_the_shell_environment(self):
        on = "FIREFOX_PRIVATE_BROWSING=true"
        off = "FIREFOX_PRIVATE_BROWSING=false"
        self.assertEqual(self.entry_from(off, FIREFOX_PRIVATE_BROWSING=None), f"{self.PREF}=false")
        self.assertEqual(
            self.entry_from(on, FIREFOX_PRIVATE_BROWSING="false"), f"{self.PREF}=false"
        )
        self.assertEqual(self.entry_from(off, FIREFOX_PRIVATE_BROWSING="true"), f"{self.PREF}=true")

    def test_other_values_reach_the_container_unchanged(self):
        # Compose cannot check a value; the init script in the container does.
        for value in ("yes", "True", "1"):
            with self.subTest(value=value):
                line = f"FIREFOX_PRIVATE_BROWSING={value}"
                self.assertEqual(
                    self.entry_from(line, FIREFOX_PRIVATE_BROWSING=None), f"{self.PREF}={value}"
                )

    def test_the_check_is_mounted_where_the_image_runs_it(self):
        firefox = compose_config(FIREFOX_PRIVATE_BROWSING=None)["services"]["firefox"]
        target = f"/etc/cont-init.d/{self.INIT_SCRIPT.name}"
        mounts = [v for v in firefox.get("volumes", []) if v.get("target") == target]
        self.assertEqual(len(mounts), 1, firefox.get("volumes"))
        self.assertEqual(mounts[0]["source"], str(self.INIT_SCRIPT))
        self.assertIs(mounts[0].get("read_only"), True)


class ComposeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = compose_config()
        cls.services = cls.config["services"]

    def test_expected_services_exist(self):
        # The other tests look services up by name; a rename must fail here, not pass vacuously.
        self.assertEqual(set(self.services), {VPN, AUTOHEAL, AUTOHEAL_PROXY, *BEHIND_VPN})

    def test_every_image_is_pinned_by_tag_and_digest(self):
        # Or, for a service built here, by the commit and base digest it is built from.
        for name, service in self.services.items():
            with self.subTest(service=name):
                if "build" in service:
                    self.assertEqual(build_pin_problems(service), [])
                else:
                    self.assertRegex(service.get("image", ""), PINNED_IMAGE)

    def test_autoheal_is_built_here(self):
        # Upstream has no version tags: its Hub image is :latest, rebuilt daily.
        self.assertIn("build", self.services[AUTOHEAL])
        self.assertEqual(
            self.services[AUTOHEAL]["build"]["context"].partition("#")[0],
            "https://github.com/willfarrell/docker-autoheal.git",
        )

    def test_autoheal_runs_as_nobody_with_a_healthcheck(self):
        autoheal = self.services[AUTOHEAL]
        self.assertEqual(autoheal.get("user"), NOBODY)
        self.assertTrue(autoheal.get("healthcheck", {}).get("test"), "no healthcheck")
        # The image installs tzdata, so TZ gives its log local times.
        self.assertIn("tzdata", autoheal["build"]["dockerfile_inline"])
        self.assertIn("TZ", autoheal.get("environment", {}))

    def test_autoheal_waits_for_a_restart_to_finish(self):
        # Autoheal's curl gives up after CURL_TIMEOUT seconds, restart included. A restart
        # waits up to the stop timeout for the container to stop, then starts it: with a
        # client timeout no longer than that, Autoheal logged a restart that went through
        # as failed. The proxy must not cut the request first either.
        environment = self.services[AUTOHEAL].get("environment", {})
        curl_timeout = int(environment.get("CURL_TIMEOUT", "30"))
        stop_timeouts = [int(environment.get("AUTOHEAL_DEFAULT_STOP_TIMEOUT", "10"))]
        stop_timeouts += [
            int(service["labels"]["autoheal.stop.timeout"])
            for service in self.services.values()
            if "autoheal.stop.timeout" in service.get("labels", {})
        ]
        self.assertGreaterEqual(curl_timeout, max(stop_timeouts) + RESTART_MARGIN)
        self.assertLess(curl_timeout, proxy_server_timeout_seconds())

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

    def test_hardened_services_have_a_healthcheck(self):
        for name in HARDENED:
            with self.subTest(service=name):
                self.assertTrue(self.services[name].get("healthcheck", {}).get("test"))

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

    def test_gluetun_status_files_need_no_capability(self):
        # Gluetun (v3.41.3) makes /tmp/gluetun with mode 0644, no search bit, so creating a
        # file in it takes DAC_OVERRIDE, and it chowns each file it writes there to PUID:PGID,
        # which takes CHOWN unless they are 0 (and DAC_OVERRIDE to rewrite a file owned by
        # another user). A tmpfs made 0755 is a directory Gluetun keeps as it is, and with
        # PUID and PGID 0 it writes root's files: no capability needed. Gluetun runs as root
        # either way; PUID is not a process user with WireGuard.
        vpn = self.services[VPN]
        environment = vpn.get("environment", {})
        self.assertEqual(environment.get("PUID"), "0")
        self.assertEqual(environment.get("PGID"), "0")
        self.assertIn(f"{GLUETUN_STATUS_DIR}:mode=0755", vpn.get("tmpfs", []))
        # A status file moved out of the tmpfs would be back in a directory Gluetun cannot
        # write without those capabilities (or in the ./config/gluetun bind mount).
        for name in GLUETUN_STATUS_FILE_VARIABLES:
            with self.subTest(variable=name):
                path = environment.get(name)
                if path is not None:
                    self.assertTrue(path.startswith(f"{GLUETUN_STATUS_DIR}/"), path)

    def test_gluetun_auth_file_holds_only_qstickys_role_with_its_key(self):
        # One copy of the key: .env's GLUETUN_API_KEY, which Compose puts in both qSticky's
        # environment and the auth file it writes for Gluetun.
        content = self.config.get("configs", {}).get(GLUETUN_AUTH_CONFIG, {}).get("content")
        self.assertIsNotNone(content, f"no top-level config {GLUETUN_AUTH_CONFIG} with content")
        auth = tomllib.loads(content)
        self.assertEqual(set(auth), {"roles"})
        self.assertEqual(len(auth["roles"]), 1, auth["roles"])
        role = auth["roles"][0]
        self.assertEqual(set(role), {"name", "routes", "auth", "apikey"})
        self.assertEqual(role["auth"], "apikey")
        # Not the settings routes (they include the WireGuard private key) and no PUT.
        self.assertEqual(role["routes"], QSTICKY_ROUTES)
        qsticky = self.services["qsticky"].get("environment", {})
        self.assertEqual(qsticky.get("GLUETUN_AUTH_TYPE"), "apikey")
        self.assertTrue(role["apikey"], "empty API key")
        self.assertEqual(role["apikey"], qsticky.get("GLUETUN_APIKEY"))

    def test_gluetun_reads_the_auth_file_compose_writes(self):
        vpn = self.services[VPN]
        configs = [c for c in vpn.get("configs", []) if c.get("source") == GLUETUN_AUTH_CONFIG]
        self.assertEqual(len(configs), 1, vpn.get("configs"))
        target = configs[0].get("target", "")
        path = vpn.get("environment", {}).get("HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH")
        self.assertEqual(path, target)
        # Only root may read it (Gluetun runs as root).
        self.assertEqual(configs[0].get("mode"), "0400")
        # Not inside a mount: Compose copies the file into the container, and inside the
        # ./config/gluetun bind mount (/gluetun) the key would land in that host folder.
        for volume in vpn.get("volumes", []):
            with self.subTest(volume=volume.get("target")):
                mount = volume.get("target", "").rstrip("/")
                self.assertFalse(target == mount or target.startswith(f"{mount}/"), target)

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

    def test_read_only_root_filesystems_where_the_image_allows_it(self):
        for name in HARDENED:
            with self.subTest(service=name):
                service = self.services[name]
                if name in READ_ONLY_TMPFS:
                    self.assertIs(service.get("read_only"), True)
                    self.assertEqual(set(service.get("tmpfs", [])), READ_ONLY_TMPFS[name])
                else:
                    self.assertFalse(service.get("read_only", False))

    def test_hardened_services_rotate_their_logs(self):
        # Explicit, not the daemon's default: a stock Docker Engine keeps json-file logs
        # without limit. One definition (x-logging) for all.
        for name in HARDENED:
            with self.subTest(service=name):
                self.assertEqual(self.services[name].get("logging"), LOGGING)

    def test_firefox_sets_its_privacy_and_window_prefs(self):
        environment = self.services["firefox"].get("environment", {})
        prefs = {v for k, v in environment.items() if k.startswith("FF_PREF_")}
        self.assertLessEqual(FIREFOX_PREFS, prefs)

    def test_firefox_streams_its_audio_to_the_web_ui(self):
        # The image's default is 0: no PulseAudio server, no recorder, no /websockify-audio,
        # and the web UI hides its audio controls, so pages play without sound.
        self.assertEqual(self.services["firefox"].get("environment", {}).get("WEB_AUDIO"), "1")

    def test_firefox_is_restarted_in_place_when_it_exits(self):
        # The image's default is 0: Firefox exiting (quitting, closing its last window, a crash)
        # stops the container. 1 starts Firefox again in the running container.
        environment = self.services["firefox"].get("environment", {})
        self.assertEqual(environment.get("KEEP_APP_RUNNING"), "1")

    def test_firefox_mounts_each_patched_image_file_read_only(self):
        # Each file tests/image_overlays.py checks against the image's is mounted over that
        # file, and no other file is mounted over the image's noVNC client or its services
        # (/etc/services.d): an overlay without the check, or a check of a file nothing
        # mounts, fails here.
        mounted = {
            volume["target"]: volume
            for volume in self.services["firefox"].get("volumes", [])
            if volume.get("target", "").startswith(("/opt/noVNC/", "/etc/services.d/"))
        }
        overlays = {overlay.target: overlay for overlay in image_overlays()}
        # Files of the repo's own, not overlays of the image's: no image file to check them
        # against. The image has no /etc/services.d/xrdb/sync; the file adds the sync flag to
        # its xrdb service (tests/image_overlays.py checks that the image still has that
        # service, and no sync file of its own).
        own = {
            "/opt/noVNC/core/util/cursor-keyword.js",
            "/opt/noVNC/core/util/core-glyphs.js",
            "/etc/services.d/xrdb/sync",
        }
        self.assertEqual(set(mounted), set(overlays) | own)
        for target, overlay in overlays.items():
            with self.subTest(target=target):
                self.assertEqual(mounted[target]["source"], str(overlay.path))
                self.assertIs(mounted[target].get("read_only"), True)

    def test_firefox_mounts_the_shutdown_script_overlay_read_only(self):
        # The image's /etc/services.d/app/kill presses Ctrl+Q when the container stops, which
        # asks for confirmation here; the overlay presses Ctrl+Alt+Shift+Q instead.
        kill = next(
            volume
            for volume in self.services["firefox"].get("volumes", [])
            if volume.get("target") == "/etc/services.d/app/kill"
        )
        self.assertEqual(kill["source"], str(REPO_ROOT / "config" / "firefox-services" / "kill"))
        self.assertIs(kill.get("read_only"), True)

    def test_firefox_mounts_the_xrdb_sync_flag_read_only(self):
        # The image's supervisor (cinit) checks once, right after starting the xrdb service,
        # that it is still running, and stops the container when it has already exited (it
        # takes milliseconds). With sync it waits for xrdb's exit instead. cinit reads the file
        # as a boolean: 1 (with or without a newline), true, yes or an empty file turn it on;
        # 0 or false leave it off; text that is not a boolean stops the container (measured
        # with each of these). It runs an executable file and reads its output instead, so
        # this one must not be executable.
        source = REPO_ROOT / "config" / "firefox-services" / "xrdb-sync"
        sync = [
            volume
            for volume in self.services["firefox"].get("volumes", [])
            if volume.get("target") == "/etc/services.d/xrdb/sync"
        ]
        self.assertEqual(len(sync), 1)
        self.assertEqual(sync[0]["source"], str(source))
        self.assertIs(sync[0].get("read_only"), True)
        self.assertEqual(source.read_bytes(), b"1\n")
        self.assertEqual(source.stat().st_mode & 0o111, 0)
        # The file tests/image_overlays.py checks the image's xrdb service for.
        self.assertIn(
            ("config/firefox-services", "xrdb-sync", "/etc/services.d/xrdb/sync"),
            [tuple(addition)[:3] for addition in image_overlay_additions()],
        )
        # The browser and e2e tests start Firefox with it too (tests/e2e/service_args.py).
        self.assertIn(f"{source}:/etc/services.d/xrdb/sync:ro", e2e_service_args(self.config))

    def test_firefox_cursor_size_matches_the_theme(self):
        size = self.services["firefox"].get("environment", {}).get("XCURSOR_SIZE")
        self.assertEqual(size, str(generator_nominal_size()))


class BuildPinRuleTests(unittest.TestCase):
    """build_pin_problems accepts a build only when its inputs are fixed."""

    COMMIT = "f535158fbafcc34b2329249b5eaa1f3224cf9a32"
    DIGEST = "be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"

    def service(self) -> dict:
        return {
            "image": f"vpn-in-container/autoheal:f535158-alpine3.24.3-{self.DIGEST[:12]}",
            "pull_policy": "never",
            "build": {
                "context": f"https://github.com/willfarrell/docker-autoheal.git#{self.COMMIT}",
                "dockerfile_inline": f"FROM alpine:3.24.3@sha256:{self.DIGEST}\nRUN true\n",
                "labels": {
                    "org.opencontainers.image.revision": self.COMMIT,
                    "org.opencontainers.image.base.name": "alpine:3.24.3",
                    "org.opencontainers.image.base.digest": f"sha256:{self.DIGEST}",
                },
            },
        }

    def test_a_pinned_build_passes(self):
        self.assertEqual(build_pin_problems(self.service()), [])

    def test_unpinned_builds_fail(self):
        def context(value):
            return lambda s: s["build"].update(context=value)

        def dockerfile(value):
            return lambda s: s["build"].update(dockerfile_inline=value)

        repo = "https://github.com/willfarrell/docker-autoheal.git"
        cases = {
            "short commit": context(f"{repo}#f535158"),
            "branch": context(f"{repo}#main"),
            "no ref": context(repo),
            "a commit and a subdirectory": context(f"{repo}#{self.COMMIT}:sub"),
            "not GitHub": context(f"https://example.com/x/y.git#{self.COMMIT}"),
            "local context": context("."),
            "FROM by tag only": dockerfile("FROM alpine:3.24.3\n"),
            "FROM by digest only": dockerfile(f"FROM alpine@sha256:{self.DIGEST}\n"),
            "FROM from a build arg": dockerfile(
                f"ARG A=3.24.3@sha256:{self.DIGEST}\nFROM alpine:${{A}}\n"
            ),
            "an unpinned second stage": dockerfile(
                f"FROM alpine:3.24.3@sha256:{self.DIGEST} AS one\nFROM alpine:3.24\n"
            ),
            "a syntax line": dockerfile(
                f"# syntax=docker/dockerfile:1\nFROM alpine:3.24.3@sha256:{self.DIGEST}\n"
            ),
            "no dockerfile_inline": lambda s: s["build"].pop("dockerfile_inline"),
            "the context's Dockerfile": lambda s: s["build"].update(dockerfile="Dockerfile"),
            "build args": lambda s: s["build"].update(args={"ALPINE_VERSION": "3.18"}),
            "pull_policy missing": lambda s: s.pop("pull_policy"),
            "pull_policy build": lambda s: s.update(pull_policy="build"),
            "a tag without the inputs": lambda s: s.update(
                image="vpn-in-container/autoheal:latest"
            ),
            "a tag with an old commit": lambda s: s.update(
                image=f"vpn-in-container/autoheal:0000000-alpine3.24.3-{self.DIGEST[:12]}"
            ),
            "a label with an old commit": lambda s: s["build"]["labels"].update(
                {"org.opencontainers.image.revision": "0" * 40}
            ),
            "no labels": lambda s: s["build"].pop("labels"),
        }
        for name, change in cases.items():
            with self.subTest(case=name):
                service = self.service()
                change(service)
                self.assertNotEqual(build_pin_problems(service), [])


if __name__ == "__main__":
    unittest.main()
