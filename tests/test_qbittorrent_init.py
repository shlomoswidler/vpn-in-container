"""Tests for config/qbittorrent-init.d/10-configure-qbittorrent.sh.

Runs the script with bash against sample qBittorrent.conf files in the layouts
before qBittorrent 5.3 (WebUI keys under [Preferences]) and from 5.3 on (their
own [WebUI] section). Run: python3 -m unittest discover -s tests
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
SCRIPT = REPO_ROOT / "config" / "qbittorrent-init.d" / "10-configure-qbittorrent.sh"
BASH = shutil.which("bash") or "bash"

WEBUI = {
    "Address": "*",
    # Host-header validation: only the names the clients use (DNS rebinding defense).
    "HostHeaderValidation": "true",
    # Quoted: in Qt's INI format an unquoted ";" starts a comment, so qBittorrent would
    # read just "localhost" (Qt quotes such values itself when it writes them).
    "ServerDomains": '"localhost;127.0.0.1"',
    "AuthSubnetWhitelist": "192.168.0.0/16, 172.16.0.0/12, 10.0.0.0/8",
    "AuthSubnetWhitelistEnabled": "true",
    "LocalHostAuth": "false",
}
BITTORRENT = {
    "Session\\DefaultSavePath": "/downloads/",
    "Session\\TempPath": "/downloads/incomplete/",
    "Session\\TempPathEnabled": "true",
    "Session\\AddTorrentStopped": "false",
    "Session\\ShareLimitAction": "Stop",
}

# The watched folder for the .torrent hand-off from Firefox: torrents dropped in /watch
# are added and saved to /downloads/, not by category (automatic torrent management off).
WATCH_ENTRY = {
    "add_torrent_params": {"save_path": "/downloads/", "use_auto_tmm": False},
    "recursive": False,
}
# Watched folders a user added in the WebUI, as qBittorrent 5.3 writes them.
OTHER_FOLDERS = {
    "/downloads/other-watch": {
        "add_torrent_params": {"category": "linux", "save_path": "", "use_auto_tmm": True},
        "recursive": True,
    },
    "/config/more": {"add_torrent_params": {}, "recursive": False},
}

PRE_53 = """\
[BitTorrent]
Session\\DefaultSavePath=/somewhere/
Session\\Port=6881

[Meta]
MigrationVersion=8

[Network]
PortForwardingEnabled=true

[Preferences]
WebUI\\Address=127.0.0.1
WebUI\\LocalHostAuth=true
WebUI\\Password_PBKDF2="@ByteArray(secret)"
WebUI\\Port=9080
"""

FROM_53 = """\
[BitTorrent]
Session\\Port=6881

[Meta]
MigrationVersion=12

[Network]
PortForwardingEnabled=true

[Preferences]
General\\Locale=en

[WebUI]
Address=127.0.0.1
LocalHostAuth=true
Password_PBKDF2="@ByteArray(secret)"
Port=9080
"""


def parse(text: str) -> dict[str, list[tuple[str, str]]]:
    """Return {section: [(key, value), ...]} preserving order and duplicates."""
    sections: dict[str, list[tuple[str, str]]] = {}
    current = None
    for line in text.splitlines():
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, [])
        elif "=" in line and current is not None:
            key, value = line.split("=", 1)
            sections[current].append((key, value))
    return sections


class InitScriptTests(unittest.TestCase):
    def run_script(self, conf: str) -> dict[str, list[tuple[str, str]]]:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "qBittorrent.conf"
            path.write_text(conf)
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                env={**os.environ, "QBT_CONF_FILE": str(path)},
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return parse(path.read_text())

    def assert_section(self, sections, section: str, expected: dict[str, str]) -> None:
        entries = sections.get(section, [])
        for key, value in expected.items():
            matches = [v for k, v in entries if k == key]
            self.assertEqual(matches, [value], f"[{section}] {key}")

    def test_pre_53_layout_keeps_webui_keys_in_preferences(self):
        sections = self.run_script(PRE_53)
        self.assertNotIn("WebUI", sections)
        self.assert_section(sections, "Preferences", {f"WebUI\\{k}": v for k, v in WEBUI.items()})
        self.assert_section(sections, "BitTorrent", BITTORRENT)
        self.assert_section(sections, "Network", {"PortForwardingEnabled": "false"})

    def test_53_layout_writes_the_webui_section(self):
        sections = self.run_script(FROM_53)
        self.assert_section(sections, "WebUI", WEBUI)
        stray = [k for k, _ in sections["Preferences"] if k.startswith("WebUI\\")]
        self.assertEqual(stray, [], "no dead WebUI\\ keys under [Preferences]")
        self.assert_section(sections, "BitTorrent", BITTORRENT)

    def test_keeps_unrelated_settings_and_the_password(self):
        for conf, section, password_key in (
            (PRE_53, "Preferences", "WebUI\\Password_PBKDF2"),
            (FROM_53, "WebUI", "Password_PBKDF2"),
        ):
            with self.subTest(section=section):
                sections = self.run_script(conf)
                self.assert_section(sections, section, {password_key: '"@ByteArray(secret)"'})
                self.assert_section(sections, "BitTorrent", {"Session\\Port": "6881"})
                self.assert_section(sections, "Meta", {})

    def test_is_idempotent(self):
        for conf in (PRE_53, FROM_53):
            with self.subTest(conf=conf.splitlines()[-1]):
                once = self.run_script(conf)
                with tempfile.TemporaryDirectory() as tmp:
                    path = Path(tmp) / "qBittorrent.conf"
                    path.write_text(conf)
                    env = {**os.environ, "QBT_CONF_FILE": str(path)}
                    for _ in range(2):
                        subprocess.run(["bash", str(SCRIPT)], env=env, check=True,
                                       capture_output=True, timeout=60)  # fmt: skip
                    self.assertEqual(parse(path.read_text()), once)

    def test_adds_missing_sections(self):
        sections = self.run_script("[Meta]\nMigrationVersion=8\n")
        self.assert_section(sections, "Preferences", {f"WebUI\\{k}": v for k, v in WEBUI.items()})
        self.assert_section(sections, "BitTorrent", BITTORRENT)
        self.assert_section(sections, "Network", {"PortForwardingEnabled": "false"})

    def test_removes_duplicate_keys(self):
        conf = FROM_53.replace("LocalHostAuth=true\n", "LocalHostAuth=true\nLocalHostAuth=true\n")
        sections = self.run_script(conf)
        self.assert_section(sections, "WebUI", {"LocalHostAuth": "false"})


class WatchedFolderTests(unittest.TestCase):
    """The script makes /watch a watched folder in watched_folders.json, next to
    qBittorrent.conf, and keeps any other watched folder the user added."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.conf = self.dir / "qBittorrent.conf"
        self.conf.write_text(FROM_53)
        self.watch_file = self.dir / "watched_folders.json"

    def run_script(self, path: str | None = None) -> subprocess.CompletedProcess:
        env = {**os.environ, "QBT_CONF_FILE": str(self.conf)}
        if path is not None:
            env["PATH"] = path
        # bash by its full path: the PATH given may not contain it.
        return subprocess.run(
            [BASH, str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60,
            check=False,
        )  # fmt: skip

    def watched(self) -> dict:
        return json.loads(self.watch_file.read_text())

    def assert_configured_rest(self) -> None:
        # A problem with the watched folders must not stop the other settings.
        sections = parse(self.conf.read_text())
        self.assertEqual([v for k, v in sections["WebUI"] if k == "LocalHostAuth"], ["false"])
        self.assertEqual(
            [v for k, v in sections["BitTorrent"] if k == "Session\\DefaultSavePath"],
            ["/downloads/"],
        )

    def test_creates_the_file_when_missing(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(self.watched(), {"/watch": WATCH_ENTRY})
        self.assertIn("[qbt-init] Adding /watch to the watched folders\n", result.stdout)
        self.assert_configured_rest()

    def test_treats_an_empty_file_as_no_watched_folders(self):
        for content in ("", "\n", "{}"):
            with self.subTest(content=content):
                self.watch_file.write_text(content)
                result = self.run_script()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.watched(), {"/watch": WATCH_ENTRY})

    def test_adds_watch_and_keeps_the_other_folders(self):
        self.watch_file.write_text(json.dumps(OTHER_FOLDERS, indent=4))
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.watched(), {**OTHER_FOLDERS, "/watch": WATCH_ENTRY})
        # Existing entries keep their order; /watch is added after them.
        self.assertEqual(list(self.watched()), [*OTHER_FOLDERS, "/watch"])

    def test_leaves_a_file_that_already_watches_watch_untouched(self):
        # The user may have changed /watch's options in the WebUI: keep them.
        custom = {"/watch": {**WATCH_ENTRY, "recursive": True}, **OTHER_FOLDERS}
        for key in ("/watch", "/watch/"):
            with self.subTest(key=key):
                text = json.dumps({key: custom["/watch"], **OTHER_FOLDERS}, indent=4)
                self.watch_file.write_text(text)
                result = self.run_script()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.watch_file.read_text(), text, "file was rewritten")
                self.assertIn("[qbt-init] /watch is already a watched folder\n", result.stdout)

    def test_is_idempotent(self):
        self.watch_file.write_text(json.dumps(OTHER_FOLDERS))
        self.assertEqual(self.run_script().returncode, 0)
        once = self.watch_file.read_text()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.watch_file.read_text(), once)
        self.assertIn("[qbt-init] /watch is already a watched folder\n", result.stdout)

    def test_keeps_the_mode_of_an_existing_file(self):
        self.watch_file.write_text("{}")
        self.watch_file.chmod(0o640)
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.watch_file.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.watched(), {"/watch": WATCH_ENTRY})

    def test_leaves_an_unreadable_file_alone_and_says_so(self):
        for content in ("{not json", "[]", '"/watch"', '{"/other": 1} trailing'):
            with self.subTest(content=content):
                self.watch_file.write_text(content)
                result = self.run_script()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.watch_file.read_text(), content, "file was changed")
                self.assertIn(
                    f"[qbt-init] {self.watch_file} is not a JSON object; "
                    "not adding /watch (fix or delete the file)\n",
                    result.stderr,
                )
                self.assert_configured_rest()

    def test_reports_a_missing_jq(self):
        # A PATH with every tool the script uses except jq.
        bin_dir = self.dir / "bin"
        bin_dir.mkdir()
        for tool in ("awk", "cat", "chmod", "cp", "dirname", "grep", "mktemp", "rm", "sleep"):
            found = shutil.which(tool)
            self.assertIsNotNone(found, tool)
            (bin_dir / tool).symlink_to(found)
        result = self.run_script(path=str(bin_dir))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.watch_file.exists())
        self.assertIn("[qbt-init] jq not found; not adding /watch\n", result.stderr)
        self.assert_configured_rest()


class MissingConfigTests(unittest.TestCase):
    """The config file is created by qBittorrent's first start; the script waits for it.

    QBT_CONF_WAIT (default 30) shortens the wait for these tests.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.conf = self.dir / "qBittorrent" / "qBittorrent.conf"

    def env(self, wait: str) -> dict[str, str]:
        return {**os.environ, "QBT_CONF_FILE": str(self.conf), "QBT_CONF_WAIT": wait}

    def run_script(self, wait: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", str(SCRIPT)], env=self.env(wait), capture_output=True, text=True,
            timeout=60, check=False,
        )  # fmt: skip

    def test_skips_and_exits_0_when_the_file_never_appears(self):
        result = self.run_script("0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "[qbt-init] Starting qBittorrent configuration...\n"
            "[qbt-init] Config file not found, skipping\n",
        )
        self.assertEqual(result.stderr, "")
        self.assertEqual(list(self.dir.iterdir()), [], "created a file or directory")

    def test_waits_the_given_number_of_seconds(self):
        start = time.monotonic()
        result = self.run_script("2")
        elapsed = time.monotonic() - start
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Config file not found, skipping", result.stdout)
        self.assertGreaterEqual(elapsed, 2)
        self.assertLess(elapsed, 10)

    def test_configures_a_file_that_appears_while_waiting(self):
        with subprocess.Popen(
            ["bash", str(SCRIPT)], env=self.env("20"), stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
        ) as process:  # fmt: skip
            time.sleep(1.5)
            self.assertIsNone(process.poll(), "the script did not wait for the file")
            self.conf.parent.mkdir()
            self.conf.write_text(FROM_53)
            stdout, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertTrue(stdout.endswith("[qbt-init] Configuration complete\n"), stdout)
        self.assertEqual(parse(self.conf.read_text())["WebUI"][0], ("Address", "*"))

    def test_rejects_a_wait_that_is_not_a_whole_number(self):
        for wait in ("abc", "-1", "1.5", "08", " 3"):
            with self.subTest(wait=wait):
                result = self.run_script(wait)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(
                    result.stderr,
                    f"[qbt-init] QBT_CONF_WAIT must be a whole number of seconds, not '{wait}'\n",
                )
                self.assertEqual(list(self.dir.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
