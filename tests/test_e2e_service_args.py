"""Tests for tests/e2e/service_args.py, which turns the firefox service into `docker run` args.

tests/e2e/run.sh starts its Firefox containers with these arguments, so they decide whether
the e2e test runs Firefox with the service's settings: the browser environment, the
read-only mounts and the security options.
Run: python3 -m unittest discover -s tests
"""

import importlib.util
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SERVICE_ARGS = REPO_ROOT / "tests" / "e2e" / "service_args.py"


def load_service_args():
    spec = importlib.util.spec_from_file_location("service_args", SERVICE_ARGS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.service_args


def option_values(args: list[str], flag: str) -> list[str]:
    """The values that follow each FLAG in ARGS."""
    return [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == flag]


class ServiceArgsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.service_args = staticmethod(load_service_args())

    def args(self, **service) -> list[str]:
        return self.service_args({"services": {"firefox": {"image": "example:1", **service}}})

    def test_the_image_comes_first(self):
        self.assertEqual(self.args(), ["example:1"])

    def test_browser_environment_and_ff_prefs_pass_through(self):
        args = self.args(
            environment={
                "XCURSOR_SIZE": "24",
                "WEB_AUDIO": "1",
                "FF_PREF_B": "b.pref=1",
                "FF_PREF_A": "a.pref=true",
                "WEB_AUTHENTICATION": "0",
            }
        )
        self.assertEqual(
            option_values(args, "-e"),
            ["XCURSOR_SIZE=24", "WEB_AUDIO=1", "FF_PREF_A=a.pref=true", "FF_PREF_B=b.pref=1"],
        )

    def test_only_read_only_mounts_under_the_browser_directories_pass_through(self):
        args = self.args(
            volumes=[
                {"source": "/r/cursors", "target": "/usr/share/icons/x", "read_only": True},
                {"source": "/r/init.sh", "target": "/etc/cont-init.d/57.sh", "read_only": True},
                {"source": "/r/config", "target": "/config"},
                {"source": "/r/other", "target": "/srv/other", "read_only": True},
            ]
        )
        self.assertEqual(
            option_values(args, "-v"),
            ["/r/cursors:/usr/share/icons/x:ro", "/r/init.sh:/etc/cont-init.d/57.sh:ro"],
        )

    def test_capabilities_pass_through(self):
        args = self.args(cap_drop=["ALL"], cap_add=["CHOWN", "KILL"])
        self.assertEqual(option_values(args, "--cap-drop"), ["ALL"])
        self.assertEqual(option_values(args, "--cap-add"), ["CHOWN", "KILL"])

    def test_security_options_pass_through(self):
        args = self.args(security_opt=["no-new-privileges:true", "label=disable"])
        self.assertEqual(
            option_values(args, "--security-opt"), ["no-new-privileges:true", "label=disable"]
        )


if __name__ == "__main__":
    unittest.main()
