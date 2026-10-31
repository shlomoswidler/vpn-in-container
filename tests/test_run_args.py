"""Tests for tests/run_args.py: a service's hardening as `docker run` arguments.

Run: python3 -m unittest discover -s tests
"""

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RUN_ARGS = REPO_ROOT / "tests" / "run_args.py"


def load_hardening_args():
    spec = importlib.util.spec_from_file_location("run_args", RUN_ARGS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.hardening_args


def run(service_name: str, services: dict) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-I", str(RUN_ARGS), service_name],
        input=json.dumps({"services": services}),
        capture_output=True, text=True, timeout=30, check=False,
    )  # fmt: skip


class HardeningArgsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hardening_args = staticmethod(load_hardening_args())

    def test_a_service_without_hardening_gets_no_arguments(self):
        self.assertEqual(self.hardening_args({"image": "example:1"}), [])

    def test_security_options_and_capabilities(self):
        service = {
            "security_opt": ["no-new-privileges:true"],
            "cap_drop": ["ALL"],
            "cap_add": ["CHOWN", "SETUID"],
        }
        self.assertEqual(
            self.hardening_args(service),
            [
                "--security-opt", "no-new-privileges:true",
                "--cap-drop", "ALL",
                "--cap-add", "CHOWN",
                "--cap-add", "SETUID",
            ],
        )  # fmt: skip

    def test_pid_and_memory_limits(self):
        # As `docker compose config` resolves them: pids_limit a number, mem_limit bytes.
        service = {"pids_limit": 512, "mem_limit": "2147483648"}
        self.assertEqual(
            self.hardening_args(service), ["--pids-limit", "512", "--memory", "2147483648"]
        )

    def test_the_command_prints_one_argument_per_line(self):
        result = run("app", {"app": {"cap_drop": ["ALL"]}, "other": {"cap_add": ["KILL"]}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["--cap-drop", "ALL"])

    def test_the_command_fails_for_an_unknown_service(self):
        result = run("missing", {"app": {}})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no service 'missing'", result.stderr)


if __name__ == "__main__":
    unittest.main()
