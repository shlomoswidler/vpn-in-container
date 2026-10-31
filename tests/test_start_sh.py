"""Tests for start.sh, with stub `docker`, `open` and `xdg-open` commands on PATH.

start.sh runs from a temporary copy of the repo's start.sh and docker-compose.yml with its
own .env, so the real .env is never read. The stub docker answers `compose ps` with canned
output and fails or passes `compose up` on request; `compose config` goes to the real docker
CLI, so the tests see what Compose itself makes of the environment start.sh passed and the
.env file (no daemon or containers needed).
Run: python3 -m unittest discover -s tests
"""

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
START_SH = REPO_ROOT / "start.sh"
COMPOSE_FILE = REPO_ROOT / "docker-compose.yml"
REAL_DOCKER = shutil.which("docker")
URLS = ["http://localhost:5800", "http://localhost:9080"]
SERVICES = ["vpn", "firefox", "qbittorrent", "qsticky", "autoheal", "autoheal-proxy"]
HEALTHY = "".join(f"{name}\trunning\thealthy\n" for name in SERVICES)
# Variables start.sh may set; the tests remove them from the environment they start from.
MANAGED = ("PUID", "PGID", "DOWNLOADS_PATH")

# Logs each call (and, for `compose up`, what Compose resolves) as one JSON line.
STUB_DOCKER = """\
#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
entry = {"args": args, "env": {k: os.environ.get(k) for k in ("PUID", "PGID", "DOWNLOADS_PATH")}}
code = 0
if args[:2] == ["compose", "config"]:
    result = subprocess.run([os.environ["REAL_DOCKER"], *args], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    code = result.returncode
elif args[:2] == ["compose", "up"]:
    result = subprocess.run(
        [os.environ["REAL_DOCKER"], "compose", "config", "--format", "json"],
        capture_output=True, text=True,
    )
    entry["resolved"] = json.loads(result.stdout) if result.returncode == 0 else result.stderr
    print("stub: compose up")
    code = int(os.environ.get("STUB_UP_EXIT", "0"))
elif args[:2] == ["compose", "ps"]:
    sys.stdout.write(os.environ.get("STUB_PS", ""))
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps(entry) + "\\n")
sys.exit(code)
"""
STUB_OPEN = """\
#!/bin/sh
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$STUB_OPEN_LOG"
"""


class StartShTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(REAL_DOCKER, "these tests need the docker CLI with Compose")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.app = self.dir / "app"
        self.app.mkdir()
        shutil.copy(START_SH, self.app / "start.sh")
        shutil.copy(COMPOSE_FILE, self.app / "docker-compose.yml")
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        for name, text in (("docker", STUB_DOCKER), ("open", STUB_OPEN), ("xdg-open", STUB_OPEN)):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)
        self.log = self.dir / "docker.log"
        self.open_log = self.dir / "open.log"
        self.env = {k: v for k, v in os.environ.items() if k not in MANAGED}
        self.env.update(
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            REAL_DOCKER=REAL_DOCKER,
            STUB_LOG=str(self.log),
            STUB_OPEN_LOG=str(self.open_log),
            STUB_PS=HEALTHY,
        )

    def write_env(self, *lines: str) -> None:
        base = ["COMPOSE_PROJECT_NAME=start-sh-test", "GLUETUN_API_KEY=test"]
        (self.app / ".env").write_text("\n".join([*base, *lines]) + "\n")

    def run_start(self, **env: str) -> subprocess.CompletedProcess:
        # Through its #!/bin/bash line, as users run it (bash 3.2 on macOS).
        return subprocess.run(
            [str(self.app / "start.sh")], env={**self.env, **env}, capture_output=True,
            text=True, timeout=60, check=False,
        )  # fmt: skip

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def up_call(self) -> dict:
        ups = [call for call in self.calls() if call["args"][:2] == ["compose", "up"]]
        self.assertEqual(len(ups), 1, self.calls())
        return ups[0]

    def opened(self, expected: int = 0) -> list[str]:
        """The URLs opened, sorted; waits up to 10 s for EXPECTED of them (xdg-open runs in
        the background, so it may log after start.sh has exited)."""
        deadline = time.monotonic() + 10
        lines: list[str] = []
        while True:
            if self.open_log.exists():
                lines = self.open_log.read_text().splitlines()
            if len(lines) >= expected or time.monotonic() > deadline:
                return sorted(line.split(" ", 1)[1] for line in lines)
            time.sleep(0.1)

    def resolved(self, up: dict) -> tuple[str, str, str, str]:
        """(qBittorrent PUID, PGID, Firefox USER_ID, /downloads source) as Compose sees them."""
        self.assertIsInstance(up["resolved"], dict, up["resolved"])
        services = up["resolved"]["services"]
        qbt = services["qbittorrent"]
        downloads = [v["source"] for v in qbt["volumes"] if v["target"] == "/downloads"]
        return (
            qbt["environment"]["PUID"],
            qbt["environment"]["PGID"],
            services["firefox"]["environment"]["USER_ID"],
            downloads[0],
        )

    def test_values_from_env_file_win(self):
        self.write_env("PUID=1234", "PGID=2345", "DOWNLOADS_PATH=/srv/torrents")
        result = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        up = self.up_call()
        self.assertEqual(up["env"], {"PUID": None, "PGID": None, "DOWNLOADS_PATH": None})
        self.assertEqual(self.resolved(up), ("1234", "2345", "1234", "/srv/torrents"))
        self.assertEqual(self.opened(expected=len(URLS)), URLS)

    def test_env_file_value_forms_that_compose_reads_as_numbers(self):
        for line in (
            'PUID="1234"',
            "PUID='1234'",
            "PUID=1234 # mine",
            "  PUID = 1234",
            "export PUID=1234",
        ):
            with self.subTest(line=line):
                self.log.unlink(missing_ok=True)
                self.write_env(line, "PGID=2345")
                result = self.run_start()
                self.assertEqual(result.returncode, 0, result.stderr)
                up = self.up_call()
                self.assertIsNone(up["env"]["PUID"])
                self.assertEqual(self.resolved(up)[0], "1234")

    def test_missing_or_empty_ids_are_detected(self):
        for lines in ((), ("PUID=", "PGID="), ('PUID=""', "PGID=''")):
            with self.subTest(lines=lines):
                self.log.unlink(missing_ok=True)
                self.write_env(*lines)
                result = self.run_start()
                self.assertEqual(result.returncode, 0, result.stderr)
                up = self.up_call()
                uid, gid = str(os.getuid()), str(os.getgid())
                self.assertEqual(up["env"]["PUID"], uid)
                self.assertEqual(up["env"]["PGID"], gid)
                # DOWNLOADS_PATH is left to the compose file's default.
                self.assertIsNone(up["env"]["DOWNLOADS_PATH"])
                default = f"{os.environ['HOME']}/Downloads/vpn-in-container"
                self.assertEqual(self.resolved(up), (uid, gid, uid, default))

    def test_the_shell_environment_still_wins(self):
        self.write_env("PUID=1234", "PGID=2345")
        result = self.run_start(PUID="4321", PGID="5432", DOWNLOADS_PATH="/from/shell")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.resolved(self.up_call()), ("4321", "5432", "4321", "/from/shell"))

    def test_rejects_an_id_that_is_not_a_number(self):
        # The old .env.example line: Compose reads the comment as the value.
        for source, kwargs, shown in (
            (".env", {}, "# Run: id -u"),
            ("the environment", {"PUID": "abc"}, "abc"),
        ):
            with self.subTest(source=source):
                self.write_env("PUID=       # Run: id -u", "PGID=2345")
                result = self.run_start(**kwargs)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"PUID from {source} is '{shown}', not a number", result.stderr)
                self.assertEqual(self.calls(), [], "called docker")
                self.assertEqual(self.opened(), [])

    def test_waits_for_health_with_a_timeout(self):
        self.write_env("PUID=1234", "PGID=2345")
        for env, timeout in (({}, "300"), ({"START_WAIT_TIMEOUT": "42"}, "42")):
            with self.subTest(timeout=timeout):
                self.log.unlink(missing_ok=True)
                result = self.run_start(**env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    self.up_call()["args"],
                    ["compose", "up", "-d", "--wait", "--wait-timeout", timeout],
                )

    def test_rejects_a_timeout_that_is_not_a_whole_number(self):
        self.write_env("PUID=1234", "PGID=2345")
        result = self.run_start(START_WAIT_TIMEOUT="5m")
        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "START_WAIT_TIMEOUT must be a whole number of seconds, not '5m'", result.stderr
        )
        self.assertEqual(self.calls(), [])

    def test_a_failing_up_wait_exits_non_zero_without_opening_urls(self):
        self.write_env("PUID=1234", "PGID=2345")
        ps = "vpn\trunning\tunhealthy\nfirefox\tcreated\t\n"
        result = self.run_start(STUB_UP_EXIT="1", STUB_PS=ps)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.opened(), [])
        self.assertIn("did not become healthy within 300s", result.stderr)
        # The services' state is shown so the user sees which one failed.
        self.assertIn("vpn\trunning\tunhealthy", result.stderr)
        self.assertNotIn("Opening web interfaces", result.stdout)

    def test_checks_health_itself_when_up_wait_exits_0(self):
        # Compose v5.5.0 can exit 0 when --wait-timeout expires (fixed in v5.5.1).
        self.write_env("PUID=1234", "PGID=2345")
        for ps in (
            HEALTHY.replace("vpn\trunning\thealthy", "vpn\trunning\tunhealthy"),
            HEALTHY.replace("qsticky\trunning\thealthy", "qsticky\trunning\tstarting"),
            HEALTHY.replace("firefox\trunning\thealthy", "firefox\texited\t"),
            HEALTHY.replace("autoheal\trunning\thealthy\n", ""),
        ):
            with self.subTest(ps=ps):
                self.open_log.unlink(missing_ok=True)
                result = self.run_start(STUB_PS=ps)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(self.opened(), [])
                self.assertIn("did not become healthy within 300s", result.stderr)


if __name__ == "__main__":
    unittest.main()
