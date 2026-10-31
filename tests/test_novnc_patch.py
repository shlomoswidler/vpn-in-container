"""Tests for tests/novnc_patch.py and the files it checks.

config/novnc/cursor.js must be exactly the image's noVNC core/util/cursor.js plus
config/novnc/cursor.js.patch, and config/novnc/ui.js the image's app/ui.js plus
config/novnc/ui.js.patch. The repo does not hold the image's files, only their checksums
(config/novnc/*.upstream.sha256): each original is rebuilt here by taking the patch back out
of its overlay. tests/browser/run.sh and tests/e2e/run.sh check the image's own files against
the same checksums.
Run: python3 -m unittest discover -s tests
"""

import hashlib
import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "tests" / "novnc_patch.py"


def load_module():
    spec = importlib.util.spec_from_file_location("novnc_patch", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


npatch = load_module()

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


def overlay_named(name: str):
    return next(overlay for overlay in npatch.OVERLAYS if overlay.name == name)


UI = overlay_named("ui.js")


def original(overlay) -> bytes:
    return npatch.original_of(
        overlay.path.read_bytes(), overlay.patch_file.read_bytes(), npatch.recorded_sha256(overlay)
    )


# The image's files: noVNC v1.6.0 and v1.7.0's core/util/cursor.js, which the firefox
# image ships as is, and jlesage/firefox v26.09.1's app/ui.js (the base image's own UI).
RECORDED = {
    "cursor.js": "adabe605d73f38e5f29abd302489d4b9e98a9e495823a06a2edbe7f6744856fa",
    "ui.js": "6ee695b83157f4fa455e2580cfe2ba454cb983c6d17ba324df5aea15c872c5e4",
}
# (a line the patch adds, an edit of it), and (a line it leaves, an edit of it).
EDITS = {
    "cursor.js": (
        (b"const keyword = ", b"let keyword = "),
        (b"_position", b"_positionX"),
    ),
    "ui.js": (
        (b"// Reconnected after the first user interaction", b"// Reconnected"),
        (b"disconnectFinished(e) {", b"disconnectFinished(event) {"),
    ),
}


class PatchReaderTests(unittest.TestCase):
    def test_applies_forward_and_back(self):
        hunks = npatch.parse_patch(PATCH)
        self.assertEqual(npatch.apply_patch(OLD, hunks), NEW)
        self.assertEqual(npatch.apply_patch(NEW, hunks, reverse=True), OLD)

    def test_a_hunk_with_no_old_lines(self):
        # `@@ -0,0 +1 @@`: lines added to an empty file. A missing count means 1.
        hunks = npatch.parse_patch(b"--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+only\n")
        self.assertEqual(npatch.apply_patch(b"", hunks), b"only\n")
        self.assertEqual(npatch.apply_patch(b"only\n", hunks, reverse=True), b"")

    def test_a_changed_context_line_does_not_apply(self):
        hunks = npatch.parse_patch(PATCH)
        with self.assertRaisesRegex(npatch.PatchError, r"hunk 1 does not match at line 1"):
            npatch.apply_patch(OLD.replace(b"two", b"TWO"), hunks)

    def test_no_offset_is_allowed(self):
        # `patch` would find the hunks one line further down; this reader does not look.
        with self.assertRaisesRegex(npatch.PatchError, r"hunk 1 does not match"):
            npatch.apply_patch(b"zero\n" + OLD, npatch.parse_patch(PATCH))

    def test_a_hunk_past_the_end_does_not_apply(self):
        with self.assertRaisesRegex(npatch.PatchError, r"hunk 2 does not match"):
            npatch.apply_patch(b"one\ntwo\nthree\nfour\n", npatch.parse_patch(PATCH))

    def test_a_count_that_disagrees_with_the_lines_is_rejected(self):
        bad = PATCH.replace(b"@@ -1,4 +1,5 @@", b"@@ -1,4 +1,6 @@")
        with self.assertRaisesRegex(npatch.PatchError, r"hunk 1"):
            npatch.parse_patch(bad)

    def test_a_start_that_disagrees_with_the_other_side_is_rejected(self):
        # The second hunk's new start must follow from the first hunk's added line.
        bad = PATCH.replace(b"@@ -5,3 +6,3 @@", b"@@ -5,3 +5,3 @@")
        with self.assertRaisesRegex(npatch.PatchError, r"hunk 2 starts at line 5 of the new file"):
            npatch.apply_patch(OLD, npatch.parse_patch(bad))

    def test_overlapping_hunks_are_rejected(self):
        bad = PATCH.replace(b"@@ -5,3 +6,3 @@", b"@@ -3,3 +4,3 @@")
        with self.assertRaisesRegex(npatch.PatchError, r"hunk 2"):
            npatch.apply_patch(OLD, npatch.parse_patch(bad))

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
            with self.subTest(case=name), self.assertRaises(npatch.PatchError):
                npatch.parse_patch(text)

    def test_a_file_without_a_final_newline_is_rejected(self):
        with self.assertRaisesRegex(npatch.PatchError, r"newline"):
            npatch.apply_patch(OLD.rstrip(b"\n"), npatch.parse_patch(PATCH))


class OverlayTableTests(unittest.TestCase):
    def test_every_overlay_is_listed_with_its_image_path(self):
        self.assertEqual(
            [(overlay.name, overlay.image_path) for overlay in npatch.OVERLAYS],
            [("cursor.js", "core/util/cursor.js"), ("ui.js", "app/ui.js")],
        )

    def test_every_overlay_has_its_three_files(self):
        for overlay in npatch.OVERLAYS:
            for path in (overlay.path, overlay.patch_file, overlay.checksum_file):
                with self.subTest(path=path):
                    self.assertTrue(path.is_file())


class CommittedOverlayTests(unittest.TestCase):
    """Each config/novnc overlay is its recorded original plus its patch."""

    def test_the_recorded_checksums_are_the_image_files(self):
        for overlay in npatch.OVERLAYS:
            with self.subTest(overlay=overlay.name):
                self.assertEqual(npatch.recorded_sha256(overlay), RECORDED[overlay.name])

    def test_each_overlay_is_the_original_plus_the_patch(self):
        for overlay in npatch.OVERLAYS:
            with self.subTest(overlay=overlay.name):
                data = overlay.path.read_bytes()
                patch = overlay.patch_file.read_bytes()
                found = npatch.original_of(data, patch, npatch.recorded_sha256(overlay))
                self.assertEqual(sha256(found), npatch.recorded_sha256(overlay))
                self.assertEqual(npatch.apply_patch(found, npatch.parse_patch(patch)), data)
                self.assertNotEqual(found, data)

    def test_an_edit_inside_the_patched_lines_fails(self):
        for overlay in npatch.OVERLAYS:
            old, new = EDITS[overlay.name][0]
            with self.subTest(overlay=overlay.name):
                data = overlay.path.read_bytes()
                edited = data.replace(old, new, 1)
                self.assertNotEqual(edited, data)
                with self.assertRaisesRegex(npatch.PatchError, r"does not match"):
                    npatch.original_of(
                        edited, overlay.patch_file.read_bytes(), npatch.recorded_sha256(overlay)
                    )

    def test_an_edit_outside_the_patched_lines_fails(self):
        # Taking the patch back out still works; the result is not upstream's file.
        for overlay in npatch.OVERLAYS:
            old, new = EDITS[overlay.name][1]
            with self.subTest(overlay=overlay.name):
                data = overlay.path.read_bytes()
                edited = data.replace(old, new, 1)
                self.assertNotEqual(edited, data)
                with self.assertRaisesRegex(npatch.PatchError, r"is not the recorded original"):
                    npatch.original_of(
                        edited, overlay.patch_file.read_bytes(), npatch.recorded_sha256(overlay)
                    )

    def test_a_wrong_checksum_fails(self):
        for overlay in npatch.OVERLAYS:
            with (
                self.subTest(overlay=overlay.name),
                self.assertRaisesRegex(npatch.PatchError, r"is not the recorded original"),
            ):
                npatch.original_of(
                    overlay.path.read_bytes(), overlay.patch_file.read_bytes(), "0" * 64
                )

    def test_each_checksum_file_is_one_sha256sum_line(self):
        for overlay in npatch.OVERLAYS:
            with self.subTest(overlay=overlay.name):
                self.assertRegex(
                    overlay.checksum_file.read_text(),
                    rf"\A[0-9a-f]{{64}}  {re.escape(overlay.image_path)}\n\Z",
                )

    def test_a_checksum_line_for_another_path_is_rejected(self):
        moved = npatch.Overlay("ui.js", "core/util/cursor.js")
        # The real ui.js checksum file names app/ui.js, not core/util/cursor.js.
        self.assertEqual(moved.checksum_file, UI.checksum_file)
        with self.assertRaisesRegex(npatch.PatchError, r"core/util/cursor\.js` line"):
            npatch.recorded_sha256(moved)

    def test_the_ui_patch_only_adds_the_reconnect_branch(self):
        # Minimal: nothing upstream is removed, and the added lines are one else-if branch,
        # after the first-interaction listener, that restores audio from the volume slider.
        lines = UI.patch_file.read_bytes().splitlines()
        removed = [line for line in lines[2:] if line.startswith(b"-")]
        added = [line[1:].strip() for line in lines[2:] if line.startswith(b"+")]
        self.assertEqual(removed, [])
        self.assertEqual(added[0], b"} else if (UI.audioContext) {")
        self.assertEqual(added[-1], b"UI.updateAudioVolume();")
        self.assertTrue(all(line.startswith(b"//") for line in added[1:-1]))
        patched = UI.path.read_text()
        connect = patched.index("    connectFinished(e) {")
        branch = patched.index("} else if (UI.audioContext) {")
        disconnect = patched.index("    disconnectFinished(e) {")
        self.assertLess(connect, branch)
        self.assertLess(branch, disconnect)
        self.assertLess(patched.index("UI.audioContext.firstInteractionHandled = true;"), branch)


class CommandLineTests(unittest.TestCase):
    """The check tests/browser/run.sh and tests/e2e/run.sh run on the image's files."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.image_dir = Path(tmp.name)
        self.originals = {overlay.name: original(overlay) for overlay in npatch.OVERLAYS}

    def write_image_files(self, **changes: tuple[bytes, bytes]) -> None:
        for overlay in npatch.OVERLAYS:
            data = self.originals[overlay.name]
            change = changes.get(overlay.name.replace(".js", ""))
            if change:
                data = data.replace(*change, 1)
                self.assertNotEqual(data, self.originals[overlay.name])
            path = self.image_dir / overlay.image_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

    def run_check(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args],
            capture_output=True, text=True, timeout=30, check=False,
        )  # fmt: skip

    def test_the_recorded_originals_pass(self):
        self.write_image_files()
        result = self.run_check(str(self.image_dir))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        for overlay in npatch.OVERLAYS:
            with self.subTest(overlay=overlay.name):
                self.assertIn(f"ok    the image's noVNC {overlay.image_path}", result.stdout)
                self.assertIn(npatch.recorded_sha256(overlay), result.stdout)

    def test_a_changed_cursor_js_fails(self):
        self.write_image_files(cursor=(b"_position", b"_where"))
        result = self.run_check(str(self.image_dir))
        self.assertEqual(result.returncode, 1)
        self.assertIn("the image's noVNC core/util/cursor.js changed", result.stderr)
        self.assertIn("config/cursors/README.md", result.stderr)
        # The other file is still checked, and passes.
        self.assertIn("ok    the image's noVNC app/ui.js", result.stdout)

    def test_a_changed_ui_js_fails(self):
        self.write_image_files(ui=(b"disconnectFinished(e) {", b"disconnectFinished(ev) {"))
        result = self.run_check(str(self.image_dir))
        self.assertEqual(result.returncode, 1)
        self.assertIn("the image's noVNC app/ui.js changed", result.stderr)
        self.assertIn("config/novnc/ui.js.patch", result.stderr)
        self.assertIn("ok    the image's noVNC core/util/cursor.js", result.stdout)

    def test_a_missing_file_fails(self):
        self.write_image_files()
        missing = self.image_dir / UI.image_path
        missing.unlink()
        result = self.run_check(str(self.image_dir))
        self.assertEqual(result.returncode, 1)
        self.assertIn(str(missing), result.stderr)

    def test_usage(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage", result.stderr)


if __name__ == "__main__":
    unittest.main()
