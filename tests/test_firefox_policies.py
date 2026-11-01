"""Static tests of config/firefox-policies/policies.json, Firefox's enterprise policies.

The firefox service mounts the file at /etc/firefox/policies/policies.json.
Run: python3 -m unittest discover -s tests
"""

import json
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
POLICIES = REPO_ROOT / "config" / "firefox-policies" / "policies.json"
TORRENT_CONTROL = "{e6e36c9a-8323-446c-b720-a176017e38ff}"


class TorrentControlPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.settings = json.loads(POLICIES.read_text())["policies"]["ExtensionSettings"]

    def test_torrent_control_is_force_installed_from_amo(self):
        entry = self.settings.get(TORRENT_CONTROL, {})
        self.assertEqual(entry.get("installation_mode"), "force_installed")
        self.assertTrue(
            entry.get("install_url", "").startswith("https://addons.mozilla.org/"),
            entry.get("install_url"),
        )

    def test_torrent_control_runs_in_private_windows(self):
        # With FIREFOX_PRIVATE_BROWSING=true every window is private
        # (browser.privatebrowsing.autostart): an extension without private-browsing access
        # would do nothing. Firefox 136+ grants it from the policy at every startup, and the
        # user cannot take it away. With it off, the grant lets the extension run in a
        # private window opened on request.
        self.assertIs(self.settings.get(TORRENT_CONTROL, {}).get("private_browsing"), True)


if __name__ == "__main__":
    unittest.main()
