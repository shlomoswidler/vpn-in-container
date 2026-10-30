"""Tests for config/qbittorrent-init.d/10-configure-qbittorrent.sh.

Runs the script with bash against sample qBittorrent.conf files in the layouts
before qBittorrent 5.3 (WebUI keys under [Preferences]) and from 5.3 on (their
own [WebUI] section). Run: python3 -m unittest discover -s tests
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "config" / "qbittorrent-init.d" / "10-configure-qbittorrent.sh"

WEBUI = {
    "Address": "*",
    "ServerDomains": "*",
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


if __name__ == "__main__":
    unittest.main()
