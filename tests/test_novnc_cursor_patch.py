"""Tests for tests/novnc_cursor_patch.py and the files it checks.

config/novnc/cursor.js must be exactly the image's noVNC core/util/cursor.js plus
config/novnc/cursor.js.patch. The repo does not hold the image's file, only its checksum
(config/novnc/cursor.js.upstream.sha256): the original is rebuilt here by taking the patch
back out of config/novnc/cursor.js. tests/browser/run.sh and tests/e2e/run.sh check the
image's own file against the same checksum.
Run: python3 -m unittest discover -s tests
"""

import hashlib
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "tests" / "novnc_cursor_patch.py"


def load_module():
    spec = importlib.util.spec_from_file_location("novnc_cursor_patch", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ncp = load_module()

# A small file and a patch of it in `diff -u` form, for the patch reader's own tests.
OLD = b"one\ntwo\nthree\nfour\nfive\nsix\nseven\n"
NEW = b"one\ntwo\nthree\n3.5\nfour\nfive\nsix\nSEVEN\n"
PATCH = b"""\
--- a/f
+++ b/f
@@ -1,4 +1,5 @@
 one
 two
 three
+3.5
 four
@@ -5,3 +6,3 @@
 five
 six
-seven
+SEVEN
"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class PatchReaderTests(unittest.TestCase):
    def test_applies_forward_and_back(self):
        hunks = ncp.parse_patch(PATCH)
        self.assertEqual(ncp.apply_patch(OLD, hunks), NEW)
        self.assertEqual(ncp.apply_patch(NEW, hunks, reverse=True), OLD)

    def test_a_hunk_with_no_old_lines(self):
        # `@@ -0,0 +1 @@`: lines added to an empty file. A missing count means 1.
        hunks = ncp.parse_patch(b"--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+only\n")
        self.assertEqual(ncp.apply_patch(b"", hunks), b"only\n")
        self.assertEqual(ncp.apply_patch(b"only\n", hunks, reverse=True), b"")

    def test_a_changed_context_line_does_not_apply(self):
        hunks = ncp.parse_patch(PATCH)
        with self.assertRaisesRegex(ncp.PatchError, r"hunk 1 does not match at line 1"):
            ncp.apply_patch(OLD.replace(b"two", b"TWO"), hunks)

    def test_no_offset_is_allowed(self):
        # `patch` would find the hunks one line further down; this reader does not look.
        with self.assertRaisesRegex(ncp.PatchError, r"hunk 1 does not match"):
            ncp.apply_patch(b"zero\n" + OLD, ncp.parse_patch(PATCH))

    def test_a_hunk_past_the_end_does_not_apply(self):
        with self.assertRaisesRegex(ncp.PatchError, r"hunk 2 does not match"):
            ncp.apply_patch(b"one\ntwo\nthree\nfour\n", ncp.parse_patch(PATCH))

    def test_a_count_that_disagrees_with_the_lines_is_rejected(self):
        bad = PATCH.replace(b"@@ -1,4 +1,5 @@", b"@@ -1,4 +1,6 @@")
        with self.assertRaisesRegex(ncp.PatchError, r"hunk 1"):
            ncp.parse_patch(bad)

    def test_a_start_that_disagrees_with_the_other_side_is_rejected(self):
        # The second hunk's new start must follow from the first hunk's added line.
        bad = PATCH.replace(b"@@ -5,3 +6,3 @@", b"@@ -5,3 +5,3 @@")
        with self.assertRaisesRegex(ncp.PatchError, r"hunk 2 starts at line 5 of the new file"):
            ncp.apply_patch(OLD, ncp.parse_patch(bad))

    def test_overlapping_hunks_are_rejected(self):
        bad = PATCH.replace(b"@@ -5,3 +6,3 @@", b"@@ -3,3 +4,3 @@")
        with self.assertRaisesRegex(ncp.PatchError, r"hunk 2"):
            ncp.apply_patch(OLD, ncp.parse_patch(bad))

    def test_unsupported_input_is_rejected(self):
        cases = {
            "no file header": PATCH.split(b"\n", 2)[2],
            "two files": PATCH + b"--- a/g\n+++ b/g\n@@ -1 +1 @@\n-x\n+y\n",
            "no newline marker": PATCH + b"\\ No newline at end of file\n",
            "an unknown line": PATCH.replace(b" six\n", b"?six\n"),
            "no hunks": b"--- a/f\n+++ b/f\n",
            "a truncated hunk": PATCH.rsplit(b"+SEVEN\n", 1)[0],
        }
        for name, text in cases.items():
            with self.subTest(case=name), self.assertRaises(ncp.PatchError):
                ncp.parse_patch(text)

    def test_a_file_without_a_final_newline_is_rejected(self):
        with self.assertRaisesRegex(ncp.PatchError, r"newline"):
            ncp.apply_patch(OLD.rstrip(b"\n"), ncp.parse_patch(PATCH))


class CommittedOverlayTests(unittest.TestCase):
    """config/novnc/cursor.js is the recorded original plus config/novnc/cursor.js.patch."""

    @classmethod
    def setUpClass(cls):
        cls.overlay = ncp.OVERLAY.read_bytes()
        cls.patch = ncp.PATCH_FILE.read_bytes()
        cls.recorded = ncp.recorded_sha256()

    def test_the_recorded_checksum_is_the_image_file(self):
        # noVNC v1.6.0 and v1.7.0's core/util/cursor.js; the firefox image ships it as is.
        self.assertEqual(
            self.recorded, "adabe605d73f38e5f29abd302489d4b9e98a9e495823a06a2edbe7f6744856fa"
        )

    def test_the_overlay_is_the_original_plus_the_patch(self):
        original = ncp.original_of(self.overlay, self.patch, self.recorded)
        self.assertEqual(sha256(original), self.recorded)
        self.assertEqual(ncp.apply_patch(original, ncp.parse_patch(self.patch)), self.overlay)
        self.assertNotEqual(original, self.overlay)

    def test_an_edit_inside_the_patched_lines_fails(self):
        # A line the patch adds.
        edited = self.overlay.replace(b"const keyword = ", b"let keyword = ", 1)
        self.assertNotEqual(edited, self.overlay)
        with self.assertRaisesRegex(ncp.PatchError, r"does not match"):
            ncp.original_of(edited, self.patch, self.recorded)

    def test_an_edit_outside_the_patched_lines_fails(self):
        # Taking the patch back out still works; the result is not upstream's file.
        edited = self.overlay.replace(b"_position", b"_positionX", 1)
        self.assertNotEqual(edited, self.overlay)
        with self.assertRaisesRegex(ncp.PatchError, r"is not the recorded original"):
            ncp.original_of(edited, self.patch, self.recorded)

    def test_a_wrong_checksum_fails(self):
        wrong = "0" * 64
        with self.assertRaisesRegex(ncp.PatchError, r"is not the recorded original"):
            ncp.original_of(self.overlay, self.patch, wrong)

    def test_the_checksum_file_is_one_sha256sum_line(self):
        text = ncp.CHECKSUM_FILE.read_text()
        self.assertRegex(text, r"\A[0-9a-f]{64}  core/util/cursor\.js\n\Z")


class CommandLineTests(unittest.TestCase):
    """The check tests/browser/run.sh and tests/e2e/run.sh run on the image's file."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.image_file = Path(tmp.name) / "cursor.js"
        overlay = ncp.OVERLAY.read_bytes()
        self.original = ncp.original_of(overlay, ncp.PATCH_FILE.read_bytes(), ncp.recorded_sha256())

    def run_check(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args],
            capture_output=True, text=True, timeout=30, check=False,
        )  # fmt: skip

    def test_the_recorded_original_passes(self):
        self.image_file.write_bytes(self.original)
        result = self.run_check(str(self.image_file))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn(ncp.recorded_sha256(), result.stdout)

    def test_a_changed_image_file_fails(self):
        self.image_file.write_bytes(self.original.replace(b"_position", b"_where", 1))
        result = self.run_check(str(self.image_file))
        self.assertEqual(result.returncode, 1)
        self.assertIn("the image's noVNC core/util/cursor.js changed", result.stderr)
        self.assertIn("config/cursors/README.md", result.stderr)

    def test_a_missing_file_fails(self):
        result = self.run_check(str(self.image_file))
        self.assertEqual(result.returncode, 1)
        self.assertIn(str(self.image_file), result.stderr)

    def test_usage(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage", result.stderr)


if __name__ == "__main__":
    unittest.main()
