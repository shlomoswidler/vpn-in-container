"""Tests for tests/image_overlays.py and the files it checks.

Each overlay must be exactly the firefox image's file plus its patch: config/novnc/cursor.js
the image's /opt/noVNC/core/util/cursor.js plus config/novnc/cursor.js.patch,
config/novnc/ui.js its /opt/noVNC/app/ui.js plus config/novnc/ui.js.patch, and
config/firefox-services/kill its /etc/services.d/app/kill plus
config/firefox-services/kill.patch. The repo does not hold the image's files, only their
checksums (NAME.upstream.sha256): each original is rebuilt here by taking the patch back out of
its overlay. tests/browser/run.sh and tests/e2e/run.sh check the image's own files against the
same checksums. They also check, for each file of the repo's own added to an image directory
(config/firefox-services/xrdb-sync at /etc/services.d/xrdb/sync), that the image has the
service it is added to and no such file of its own.
Run: python3 -m unittest discover -s tests
"""

import hashlib
import importlib.util
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "tests" / "image_overlays.py"


def load_module():
    spec = importlib.util.spec_from_file_location("image_overlays", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


overlays = load_module()

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
    return next(overlay for overlay in overlays.OVERLAYS if overlay.name == name)


UI = overlay_named("ui.js")
KILL = overlay_named("kill")
XRDB_SYNC = next(addition for addition in overlays.ADDITIONS if addition.name == "xrdb-sync")


def original(overlay) -> bytes:
    return overlays.original_of(
        overlay.path.read_bytes(),
        overlay.patch_file.read_bytes(),
        overlays.recorded_sha256(overlay),
    )


# The image's files: noVNC v1.6.0 and v1.7.0's core/util/cursor.js, which the firefox
# image ships as is, and jlesage/firefox v26.09.1's app/ui.js (the base image's own UI) and
# /etc/services.d/app/kill (the script that quits Firefox when the container stops).
RECORDED = {
    "cursor.js": "adabe605d73f38e5f29abd302489d4b9e98a9e495823a06a2edbe7f6744856fa",
    "ui.js": "6ee695b83157f4fa455e2580cfe2ba454cb983c6d17ba324df5aea15c872c5e4",
    "kill": "ddd125fb476c46328927905d8ebacc8dc25f4d21c98c690b9062dc3026918df8",
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
    "kill": (
        (b'xdotool key "ctrl+alt+shift+q"', b'xdotool key "ctrl+alt+q"'),
        (b"set -u # Treat", b"set -eu # Treat"),
    ),
}


class PatchReaderTests(unittest.TestCase):
    def test_applies_forward_and_back(self):
        hunks = overlays.parse_patch(PATCH)
        self.assertEqual(overlays.apply_patch(OLD, hunks), NEW)
        self.assertEqual(overlays.apply_patch(NEW, hunks, reverse=True), OLD)

    def test_a_hunk_with_no_old_lines(self):
        # `@@ -0,0 +1 @@`: lines added to an empty file. A missing count means 1.
        hunks = overlays.parse_patch(b"--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+only\n")
        self.assertEqual(overlays.apply_patch(b"", hunks), b"only\n")
        self.assertEqual(overlays.apply_patch(b"only\n", hunks, reverse=True), b"")

    def test_a_changed_context_line_does_not_apply(self):
        hunks = overlays.parse_patch(PATCH)
        with self.assertRaisesRegex(overlays.PatchError, r"hunk 1 does not match at line 1"):
            overlays.apply_patch(OLD.replace(b"two", b"TWO"), hunks)

    def test_no_offset_is_allowed(self):
        # `patch` would find the hunks one line further down; this reader does not look.
        with self.assertRaisesRegex(overlays.PatchError, r"hunk 1 does not match"):
            overlays.apply_patch(b"zero\n" + OLD, overlays.parse_patch(PATCH))

    def test_a_hunk_past_the_end_does_not_apply(self):
        with self.assertRaisesRegex(overlays.PatchError, r"hunk 2 does not match"):
            overlays.apply_patch(b"one\ntwo\nthree\nfour\n", overlays.parse_patch(PATCH))

    def test_a_count_that_disagrees_with_the_lines_is_rejected(self):
        bad = PATCH.replace(b"@@ -1,4 +1,5 @@", b"@@ -1,4 +1,6 @@")
        with self.assertRaisesRegex(overlays.PatchError, r"hunk 1"):
            overlays.parse_patch(bad)

    def test_a_start_that_disagrees_with_the_other_side_is_rejected(self):
        # The second hunk's new start must follow from the first hunk's added line.
        bad = PATCH.replace(b"@@ -5,3 +6,3 @@", b"@@ -5,3 +5,3 @@")
        with self.assertRaisesRegex(
            overlays.PatchError, r"hunk 2 starts at line 5 of the new file"
        ):
            overlays.apply_patch(OLD, overlays.parse_patch(bad))

    def test_overlapping_hunks_are_rejected(self):
        bad = PATCH.replace(b"@@ -5,3 +6,3 @@", b"@@ -3,3 +4,3 @@")
        with self.assertRaisesRegex(overlays.PatchError, r"hunk 2"):
            overlays.apply_patch(OLD, overlays.parse_patch(bad))

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
            with self.subTest(case=name), self.assertRaises(overlays.PatchError):
                overlays.parse_patch(text)

    def test_a_file_without_a_final_newline_is_rejected(self):
        with self.assertRaisesRegex(overlays.PatchError, r"newline"):
            overlays.apply_patch(OLD.rstrip(b"\n"), overlays.parse_patch(PATCH))


class OverlayTableTests(unittest.TestCase):
    def test_every_overlay_is_listed_with_its_image_file(self):
        self.assertEqual(
            [tuple(overlay) for overlay in overlays.OVERLAYS],
            [
                ("config/novnc", "cursor.js", "/opt/noVNC", "core/util/cursor.js"),
                ("config/novnc", "ui.js", "/opt/noVNC", "app/ui.js"),
                ("config/firefox-services", "kill", "/etc/services.d/app", "kill"),
            ],
        )

    def test_the_target_is_the_image_files_absolute_path(self):
        self.assertEqual(
            [overlay.target for overlay in overlays.OVERLAYS],
            ["/opt/noVNC/core/util/cursor.js", "/opt/noVNC/app/ui.js", "/etc/services.d/app/kill"],
        )

    def test_the_repo_files_are_in_the_overlays_repo_directory(self):
        self.assertEqual(KILL.path, REPO_ROOT / "config" / "firefox-services" / "kill")
        self.assertEqual(KILL.patch_file, REPO_ROOT / "config" / "firefox-services" / "kill.patch")
        self.assertEqual(
            KILL.checksum_file,
            REPO_ROOT / "config" / "firefox-services" / "kill.upstream.sha256",
        )

    def test_every_overlay_has_its_three_files(self):
        for overlay in overlays.OVERLAYS:
            for path in (overlay.path, overlay.patch_file, overlay.checksum_file):
                with self.subTest(path=path):
                    self.assertTrue(path.is_file())

    def test_an_image_file_is_found_under_the_image_root_at_its_absolute_path(self):
        root = Path("/some/root")
        self.assertEqual(
            overlays.copied_path(root, KILL), Path("/some/root/etc/services.d/app/kill")
        )
        self.assertEqual(overlays.copied_path(root, UI), Path("/some/root/opt/noVNC/app/ui.js"))


class AdditionTableTests(unittest.TestCase):
    def test_every_addition_is_listed_with_the_file_it_needs(self):
        self.assertEqual(
            [tuple(addition) for addition in overlays.ADDITIONS],
            [
                (
                    "config/firefox-services",
                    "xrdb-sync",
                    "/etc/services.d/xrdb/sync",
                    "/etc/services.d/xrdb/run",
                ),
            ],
        )
        self.assertEqual(XRDB_SYNC.path, REPO_ROOT / "config" / "firefox-services" / "xrdb-sync")
        self.assertTrue(XRDB_SYNC.path.is_file())

    def test_each_addition_is_in_a_directory_copied_out_whole(self):
        # Only then does a file missing from the copy mean one missing from the image.
        for addition in overlays.ADDITIONS:
            for path in (addition.target, addition.required):
                with self.subTest(path=path):
                    self.assertTrue(any(overlays.in_dir(path, d) for d in overlays.COPIED_DIRS))
            with self.subTest(addition=addition.name):
                # The same service directory.
                self.assertEqual(Path(addition.target).parent, Path(addition.required).parent)

    def test_in_dir_needs_a_whole_path_component(self):
        self.assertTrue(overlays.in_dir("/etc/services.d/xrdb/run", "/etc/services.d"))
        self.assertTrue(overlays.in_dir("/etc/services.d/xrdb/run", "/etc/services.d/"))
        self.assertFalse(overlays.in_dir("/etc/services.dx/run", "/etc/services.d"))
        self.assertFalse(overlays.in_dir("/etc/services.d", "/etc/services.d"))

    def test_the_paths_to_copy_cover_every_overlay_and_none_is_inside_another(self):
        # `docker cp` of a directory onto one a file copied before it created would copy it
        # inside that one (IMAGE_ROOT/etc/services.d/services.d).
        paths = overlays.image_paths()
        self.assertEqual(
            paths, ["/etc/services.d", "/opt/noVNC/core/util/cursor.js", "/opt/noVNC/app/ui.js"]
        )
        for path in paths:
            for other in paths:
                with self.subTest(path=path, other=other):
                    self.assertFalse(overlays.in_dir(path, other))
        for overlay in overlays.OVERLAYS:
            with self.subTest(overlay=overlay.name):
                self.assertTrue(
                    overlay.target in paths
                    or any(overlays.in_dir(overlay.target, path) for path in paths)
                )


class CommittedOverlayTests(unittest.TestCase):
    """Each overlay is its recorded original plus its patch."""

    def test_the_recorded_checksums_are_the_image_files(self):
        for overlay in overlays.OVERLAYS:
            with self.subTest(overlay=overlay.name):
                self.assertEqual(overlays.recorded_sha256(overlay), RECORDED[overlay.name])

    def test_each_overlay_is_the_original_plus_the_patch(self):
        for overlay in overlays.OVERLAYS:
            with self.subTest(overlay=overlay.name):
                data = overlay.path.read_bytes()
                patch = overlay.patch_file.read_bytes()
                found = overlays.original_of(data, patch, overlays.recorded_sha256(overlay))
                self.assertEqual(sha256(found), overlays.recorded_sha256(overlay))
                self.assertEqual(overlays.apply_patch(found, overlays.parse_patch(patch)), data)
                self.assertNotEqual(found, data)

    def test_each_patch_names_its_image_path(self):
        # The same `diff -u --label a/PATH --label b/PATH` headers for every overlay.
        for overlay in overlays.OVERLAYS:
            with self.subTest(overlay=overlay.name):
                header = overlay.patch_file.read_text().splitlines()[:2]
                self.assertEqual(
                    header, [f"--- a/{overlay.image_path}", f"+++ b/{overlay.image_path}"]
                )

    def test_an_edit_inside_the_patched_lines_fails(self):
        for overlay in overlays.OVERLAYS:
            old, new = EDITS[overlay.name][0]
            with self.subTest(overlay=overlay.name):
                data = overlay.path.read_bytes()
                edited = data.replace(old, new, 1)
                self.assertNotEqual(edited, data)
                with self.assertRaisesRegex(overlays.PatchError, r"does not match"):
                    overlays.original_of(
                        edited,
                        overlay.patch_file.read_bytes(),
                        overlays.recorded_sha256(overlay),
                    )

    def test_an_edit_outside_the_patched_lines_fails(self):
        # Taking the patch back out still works; the result is not upstream's file.
        for overlay in overlays.OVERLAYS:
            old, new = EDITS[overlay.name][1]
            with self.subTest(overlay=overlay.name):
                data = overlay.path.read_bytes()
                edited = data.replace(old, new, 1)
                self.assertNotEqual(edited, data)
                with self.assertRaisesRegex(overlays.PatchError, r"is not the recorded original"):
                    overlays.original_of(
                        edited,
                        overlay.patch_file.read_bytes(),
                        overlays.recorded_sha256(overlay),
                    )

    def test_a_wrong_checksum_fails(self):
        for overlay in overlays.OVERLAYS:
            with (
                self.subTest(overlay=overlay.name),
                self.assertRaisesRegex(overlays.PatchError, r"is not the recorded original"),
            ):
                overlays.original_of(
                    overlay.path.read_bytes(), overlay.patch_file.read_bytes(), "0" * 64
                )

    def test_each_checksum_file_is_one_sha256sum_line(self):
        for overlay in overlays.OVERLAYS:
            with self.subTest(overlay=overlay.name):
                self.assertRegex(
                    overlay.checksum_file.read_text(),
                    rf"\A[0-9a-f]{{64}}  {re.escape(overlay.image_path)}\n\Z",
                )

    def test_a_checksum_line_for_another_path_is_rejected(self):
        moved = overlays.Overlay("config/novnc", "ui.js", "/opt/noVNC", "core/util/cursor.js")
        # The real ui.js checksum file names app/ui.js, not core/util/cursor.js.
        self.assertEqual(moved.checksum_file, UI.checksum_file)
        with self.assertRaisesRegex(overlays.PatchError, r"core/util/cursor\.js` line"):
            overlays.recorded_sha256(moved)

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

    def test_the_kill_patch_changes_the_quit_key_and_lints_the_wait(self):
        # The key press and the comment line naming it are replaced, and the wait loop is the
        # image's with its two shellcheck findings fixed (an unused loop variable, SC2034, and
        # `ps | grep`, SC2009): same ten checks half a second apart, for the same process.
        lines = KILL.patch_file.read_bytes().splitlines()
        removed = [line[1:] for line in lines[2:] if line.startswith(b"-")]
        added = [line[1:] for line in lines[2:] if line.startswith(b"+")]
        self.assertEqual(
            removed,
            [
                b"# CTRL+q key presses.",
                b'xdotool key "ctrl+q"',
                b"for i in $(seq 1 10)",
                b'    if ! ps | grep "/usr/lib/firefox/firefox" | grep -q -v grep',
            ],
        )
        commands = [line for line in added if not line.startswith(b"#")]
        self.assertEqual(
            commands,
            [
                b'xdotool key "ctrl+alt+shift+q"',
                b"for _ in $(seq 1 10)",
                b'    if ! pgrep -f "/usr/lib/firefox/firefox" > /dev/null',
            ],
        )
        self.assertIn(b"config/firefox-autoconfig/single-window.cfg", b"\n".join(added))

    def test_the_kill_overlay_presses_escape_then_the_quit_key_without_asking(self):
        keys = re.findall(r'^xdotool key "([^"]*)"$', KILL.path.read_text(), re.MULTILINE)
        self.assertEqual(keys, ["Escape", "ctrl+alt+shift+q"])

    def test_the_kill_overlay_is_executable(self):
        # The service manager runs it as is when the container stops; a mount keeps its mode.
        self.assertEqual(KILL.path.stat().st_mode & 0o111, 0o111)


class CommandLineTests(unittest.TestCase):
    """The check tests/browser/run.sh and tests/e2e/run.sh run on the image's files."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.image_root = Path(tmp.name)
        self.originals = {overlay.name: original(overlay) for overlay in overlays.OVERLAYS}

    def write_image_files(self, changes: dict[str, tuple[bytes, bytes]] | None = None) -> None:
        """Write each original at its absolute path under the image root, with CHANGES."""
        changes = changes or {}
        for overlay in overlays.OVERLAYS:
            data = self.originals[overlay.name]
            change = changes.get(overlay.name)
            if change:
                data = data.replace(*change, 1)
                self.assertNotEqual(data, self.originals[overlay.name])
            path = self.image_root / overlay.target.lstrip("/")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        # The image's xrdb service, as `docker cp` copies it: run is a symbolic link to a file
        # outside the copy.
        xrdb = self.image_root / "etc" / "services.d" / "xrdb"
        xrdb.mkdir(parents=True, exist_ok=True)
        (xrdb / "run").symlink_to("/opt/base/bin/xrdb")
        (xrdb / "params").write_text("/opt/base/etc/Xresources\n")
        (xrdb / "xvnc.dep").write_bytes(b"")

    def run_check(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args],
            capture_output=True, text=True, timeout=30, check=False,
        )  # fmt: skip

    def test_paths_lists_each_image_file(self):
        result = self.run_check("--paths")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        # The image's services directory whole (kill is in it, and the xrdb service the
        # addition is checked against), then the noVNC overlays.
        self.assertEqual(
            result.stdout,
            "/etc/services.d\n/opt/noVNC/core/util/cursor.js\n/opt/noVNC/app/ui.js\n",
        )

    def test_the_recorded_originals_pass(self):
        self.write_image_files()
        self.assertTrue((self.image_root / "etc" / "services.d" / "app" / "kill").is_file())
        result = self.run_check(str(self.image_root))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        for overlay in overlays.OVERLAYS:
            with self.subTest(overlay=overlay.name):
                self.assertIn(f"ok    the image's {overlay.target}", result.stdout)
                self.assertIn(overlays.recorded_sha256(overlay), result.stdout)
        self.assertIn(
            "ok    the image has /etc/services.d/xrdb/run and no /etc/services.d/xrdb/sync, "
            "which config/firefox-services/xrdb-sync adds",
            result.stdout,
        )

    def test_an_image_with_its_own_xrdb_sync_fails(self):
        # The mount would hide the image's own file.
        self.write_image_files()
        (self.image_root / "etc" / "services.d" / "xrdb" / "sync").write_text("0\n")
        result = self.run_check(str(self.image_root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  the image has its own /etc/services.d/xrdb/sync", result.stderr)
        self.assertIn("config/firefox-services/xrdb-sync", result.stderr)
        self.assertIn("config/cursors/README.md", result.stderr)
        self.assertNotIn("FAIL  the image has no", result.stderr)
        # The overlays are still checked, and pass.
        self.assertIn("ok    the image's /etc/services.d/app/kill", result.stdout)

    def test_an_image_with_its_own_xrdb_sync_link_fails(self):
        # Even a symbolic link that leads nowhere in the copy.
        self.write_image_files()
        sync = self.image_root / "etc" / "services.d" / "xrdb" / "sync"
        sync.symlink_to("/defaults/service/sync")
        result = self.run_check(str(self.image_root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  the image has its own /etc/services.d/xrdb/sync", result.stderr)

    def test_an_image_without_xrdb_run_fails(self):
        # A renamed or removed service: the mount would make a stray directory, or a service
        # without its program.
        self.write_image_files()
        (self.image_root / "etc" / "services.d" / "xrdb" / "run").unlink()
        result = self.run_check(str(self.image_root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  the image has no /etc/services.d/xrdb/run", result.stderr)
        self.assertIn("mounted at /etc/services.d/xrdb/sync", result.stderr)
        self.assertNotIn("its own /etc/services.d/xrdb/sync", result.stderr)

    def test_an_image_without_the_xrdb_service_fails(self):
        self.write_image_files()
        shutil.rmtree(self.image_root / "etc" / "services.d" / "xrdb")
        result = self.run_check(str(self.image_root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  the image has no /etc/services.d/xrdb/run", result.stderr)
        self.assertIn("Docker creates one holding only that file", result.stderr)
        self.assertIn("ok    the image's /etc/services.d/app/kill", result.stdout)

    def test_a_changed_cursor_js_fails(self):
        self.write_image_files({"cursor.js": (b"_position", b"_where")})
        result = self.run_check(str(self.image_root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("the image's /opt/noVNC/core/util/cursor.js changed", result.stderr)
        self.assertIn("config/cursors/README.md", result.stderr)
        # The other files are still checked, and pass.
        self.assertIn("ok    the image's /opt/noVNC/app/ui.js", result.stdout)
        self.assertIn("ok    the image's /etc/services.d/app/kill", result.stdout)

    def test_a_changed_ui_js_fails(self):
        self.write_image_files({"ui.js": (b"disconnectFinished(e) {", b"disconnectFinished(ev) {")})
        result = self.run_check(str(self.image_root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("the image's /opt/noVNC/app/ui.js changed", result.stderr)
        self.assertIn("config/novnc/ui.js.patch", result.stderr)
        self.assertIn("ok    the image's /opt/noVNC/core/util/cursor.js", result.stdout)

    def test_a_changed_kill_fails(self):
        # A new image's kill script that waits longer: the overlay would hide the change.
        self.write_image_files({"kill": (b"seq 1 10", b"seq 1 20")})
        result = self.run_check(str(self.image_root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("the image's /etc/services.d/app/kill changed", result.stderr)
        self.assertIn("config/firefox-services/kill.upstream.sha256", result.stderr)
        self.assertIn("re-apply config/firefox-services/kill.patch", result.stderr)
        self.assertIn("ok    the image's /opt/noVNC/app/ui.js", result.stdout)
        self.assertIn("ok    the image's /opt/noVNC/core/util/cursor.js", result.stdout)

    def test_a_missing_file_fails(self):
        self.write_image_files()
        missing = self.image_root / KILL.target.lstrip("/")
        missing.unlink()
        result = self.run_check(str(self.image_root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot read the image's /etc/services.d/app/kill", result.stderr)
        self.assertIn(str(missing), result.stderr)

    def test_files_at_their_image_relative_paths_are_not_found(self):
        # The old layout (paths under /opt/noVNC, at the root) is not accepted.
        for overlay in overlays.OVERLAYS:
            path = self.image_root / overlay.image_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(self.originals[overlay.name])
        result = self.run_check(str(self.image_root))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.count("FAIL  cannot read the image's "), 3)
        self.assertIn("FAIL  the image has no /etc/services.d/xrdb/run", result.stderr)

    def test_usage(self):
        for args in ((), (str(self.image_root), "--paths")):
            with self.subTest(args=args):
                result = self.run_check(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("usage", result.stderr)


if __name__ == "__main__":
    unittest.main()
