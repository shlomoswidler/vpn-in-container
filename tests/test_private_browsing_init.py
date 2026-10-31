"""Tests for config/firefox-init.d/54-firefox-private-browsing.sh.

The firefox service passes FIREFOX_PRIVATE_BROWSING from .env into the container as
FF_PREF_PRIVATE_BROWSING=browser.privatebrowsing.autostart=<value> (docker-compose.yml). The
image's 56-firefox-set-prefs-from-env.sh writes <value> into prefs.js as it is, and Firefox
reads anything but true as "off" without a word (measured: yes, True, 1 and "true" all left
private browsing off). The script runs first and stops the container on any other value.
Runs the script with sh and the variable set as Compose would set it.
Run: python3 -m unittest discover -s tests
"""

import os
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "config" / "firefox-init.d" / "54-firefox-private-browsing.sh"
PREF = "browser.privatebrowsing.autostart"
# The image script that writes FF_PREF_* entries into prefs.js; the check must run before it.
IMAGE_PREFS_SCRIPT = "56-firefox-set-prefs-from-env.sh"


def run_script(**variables: str | None) -> subprocess.CompletedProcess:
    """Run the script with the environment minus FF_PREF_PRIVATE_BROWSING, plus VARIABLES."""
    env = {k: v for k, v in os.environ.items() if k != "FF_PREF_PRIVATE_BROWSING"}
    env.update({k: v for k, v in variables.items() if v is not None})
    return subprocess.run(
        ["sh", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30, check=False
    )


class PrivateBrowsingInitTests(unittest.TestCase):
    def test_runs_before_the_image_writes_prefs_js(self):
        # The image runs /etc/cont-init.d in name order; docker-compose.yml mounts the script
        # there under the same name (tests/test_compose.py).
        self.assertLess(SCRIPT.name, IMAGE_PREFS_SCRIPT)
        self.assertTrue(os.access(SCRIPT, os.X_OK), "the image skips a script it cannot run")

    def test_true_and_false_pass_and_say_which(self):
        for value, shown in (
            ("true", "on (FIREFOX_PRIVATE_BROWSING=true)"),
            # Compose passes false when .env leaves the variable out.
            ("false", "off (FIREFOX_PRIVATE_BROWSING is false or unset)"),
        ):
            with self.subTest(value=value):
                result = run_script(FF_PREF_PRIVATE_BROWSING=f"{PREF}={value}")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertEqual(result.stdout, f"permanent private browsing is {shown}\n")

    def test_rejects_every_other_value(self):
        for value in (
            "yes",
            "no",
            "True",
            "FALSE",
            "1",
            "0",
            "on",
            '"true"',
            "'false'",
            "true ",
            " false",
            "true # on",
            "# on",
            "",
            "UNSET",
            "true;",
        ):
            with self.subTest(value=value):
                result = run_script(FF_PREF_PRIVATE_BROWSING=f"{PREF}={value}")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(
                    result.stderr,
                    f"FIREFOX_PRIVATE_BROWSING is '{value}', not true or false. Set it to true "
                    "or false in .env, or leave it out (off); comments go on their own line.\n",
                )

    def test_fails_without_the_entry(self):
        # Without it the image leaves the last prefs.js line in place (measured: a profile
        # that had true stayed private), so the setting would not follow .env.
        result = run_script(FF_PREF_PRIVATE_BROWSING=None)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr,
            "FF_PREF_PRIVATE_BROWSING is not set: docker-compose.yml must pass "
            f"{PREF}=<true|false> (from FIREFOX_PRIVATE_BROWSING in .env).\n",
        )

    def test_fails_for_another_pref(self):
        for entry in (
            "browser.privatebrowsing.autostart:true",
            "browser.privatebrowsing.autostartx=true",
            "true",
            "",
        ):
            with self.subTest(entry=entry):
                result = run_script(FF_PREF_PRIVATE_BROWSING=entry)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(
                    result.stderr,
                    f"FF_PREF_PRIVATE_BROWSING is '{entry}', not {PREF}=<true|false>: "
                    "docker-compose.yml must pass FIREFOX_PRIVATE_BROWSING from .env that way.\n",
                )


if __name__ == "__main__":
    unittest.main()
