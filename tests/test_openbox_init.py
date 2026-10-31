"""Tests for config/firefox-init.d/57-openbox-no-keepborder.sh and 58-openbox-no-alt-drag.sh.

Runs each script with sh on a temporary copy of tests/fixtures/openbox-rc.xml (through the
OPENBOX_RC override) and compares the result with the fixture edited here through
ElementTree, independently of the scripts' sed commands.
Run: python3 -m unittest discover -s tests

The fixture is the unmodified /var/run/openbox/rc.xml that the firefox service's image
generates at start (its /etc/cont-init.d/10-openbox.sh), without this repo's init scripts.
After changing the image in docker-compose.yml, regenerate it from the repository root:

    IMAGE=$(docker compose --env-file .env.example config --format json | python3 -I -c \\
        'import json, sys; print(json.load(sys.stdin)["services"]["firefox"]["image"])')
    docker run -d --rm --network none --name openbox-rc-capture "$IMAGE"
    until docker logs openbox-rc-capture 2>&1 | grep -q '10-openbox.sh: terminated successfully'
    do sleep 1; done
    docker cp openbox-rc-capture:/var/run/openbox/rc.xml tests/fixtures/openbox-rc.xml
    docker rm -f openbox-rc-capture

(`docker compose config` needs PUID and PGID exported, for example PUID=$(id -u) PGID=$(id -g).)
"""

import copy
import os
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INIT_DIR = REPO_ROOT / "config" / "firefox-init.d"
NO_KEEPBORDER = INIT_DIR / "57-openbox-no-keepborder.sh"
NO_ALT_DRAG = INIT_DIR / "58-openbox-no-alt-drag.sh"
FIXTURE = REPO_ROOT / "tests" / "fixtures" / "openbox-rc.xml"

NS = {"ob": "http://openbox.org/3.4/rc"}


def structure(element: ET.Element) -> tuple:
    """Comparable form of an element tree: tags, attributes, trimmed text, children."""
    return (
        element.tag,
        tuple(sorted(element.attrib.items())),
        (element.text or "").strip(),
        tuple(structure(child) for child in element),
    )


def mouse_context(root: ET.Element, name: str) -> list[ET.Element]:
    return [c for c in root.iterfind("ob:mouse/ob:context", NS) if c.get("name") == name]


def bindings(context: ET.Element) -> set[tuple[str, str, tuple[str, ...]]]:
    """(button, action, (action names...)) for each mousebind in a context."""
    return {
        (bind.get("button"), bind.get("action"),
         tuple(a.get("name") for a in bind.iterfind("ob:action", NS)))
        for bind in context.iterfind("ob:mousebind", NS)
    }  # fmt: skip


class OpenboxInitTests(unittest.TestCase):
    def setUp(self):
        self.original = FIXTURE.read_text()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.rc = Path(tmp.name) / "rc.xml"

    def run_script(self, script: Path) -> subprocess.CompletedProcess:
        result = subprocess.run(
            ["sh", str(script)],
            env={**os.environ, "OPENBOX_RC": str(self.rc)},
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        # The scripts write a temporary file next to rc.xml and must remove it.
        left = [p.name for p in self.rc.parent.iterdir() if p != self.rc]
        self.assertEqual(left, [], "temporary file left behind")
        return result

    def run_ok(self, script: Path, rc_text: str) -> str:
        self.rc.write_text(rc_text)
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return self.rc.read_text()

    def without_keepborder(self, root: ET.Element) -> ET.Element:
        root = copy.deepcopy(root)
        root.find("ob:theme/ob:keepBorder", NS).text = "no"
        return root

    def without_frame_context(self, root: ET.Element) -> ET.Element:
        root = copy.deepcopy(root)
        mouse = root.find("ob:mouse", NS)
        for context in mouse_context(root, "Frame"):
            mouse.remove(context)
        return root

    # The fixture must contain what the scripts change, or the tests below prove nothing.
    def test_fixture_has_keepborder_and_the_alt_drag_bindings(self):
        root = ET.fromstring(self.original)
        self.assertEqual(root.find("ob:theme/ob:keepBorder", NS).text, "yes")
        self.assertEqual(self.original.count("<keepBorder>yes</keepBorder>"), 1)
        (frame,) = mouse_context(root, "Frame")
        self.assertLessEqual(
            {("A-Left", "Drag", ("Move",)), ("A-Right", "Drag", ("Resize",))}, bindings(frame)
        )
        self.assertEqual(len(mouse_context(root, "Client")), 1)

    def test_57_disables_keepborder_and_changes_nothing_else(self):
        result = self.run_ok(NO_KEEPBORDER, self.original)
        root = ET.fromstring(result)
        self.assertEqual(root.find("ob:theme/ob:keepBorder", NS).text, "no")
        expected = self.without_keepborder(ET.fromstring(self.original))
        self.assertEqual(structure(root), structure(expected))

    def test_58_removes_the_alt_drag_bindings_and_keeps_the_client_ones(self):
        result = self.run_ok(NO_ALT_DRAG, self.original)
        root = ET.fromstring(result)
        original = ET.fromstring(self.original)
        # The Alt+drag Move/Resize bindings live in the Frame context (see the fixture test).
        self.assertEqual(mouse_context(root, "Frame"), [], "Frame context left in place")
        (client,) = mouse_context(root, "Client")
        (original_client,) = mouse_context(original, "Client")
        self.assertEqual(structure(client), structure(original_client))
        self.assertEqual(structure(root), structure(self.without_frame_context(original)))

    def test_both_scripts_in_container_order(self):
        result = self.run_ok(NO_ALT_DRAG, self.run_ok(NO_KEEPBORDER, self.original))
        expected = self.without_frame_context(self.without_keepborder(ET.fromstring(self.original)))
        self.assertEqual(structure(ET.fromstring(result)), structure(expected))

    def test_a_second_run_changes_nothing(self):
        for script in (NO_KEEPBORDER, NO_ALT_DRAG):
            with self.subTest(script=script.name):
                once = self.run_ok(script, self.original)
                self.assertNotEqual(once, self.original)
                self.assertEqual(self.run_ok(script, once), once)

    def test_57_fails_when_keepborder_is_missing(self):
        text, count = re.subn(r"[ \t]*<keepBorder>yes</keepBorder>\n", "", self.original)
        self.assertEqual(count, 1)
        self.rc.write_text(text)
        result = self.run_script(NO_KEEPBORDER)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, f"keepBorder is not disabled in {self.rc}\n")
        self.assertEqual(self.rc.read_text(), text)

    def test_58_fails_when_the_client_context_is_missing(self):
        client = re.compile(r'[ \t]*<context name="Client">.*?</context>\n', re.DOTALL)
        text, count = client.subn("", self.original)
        self.assertEqual(count, 1)
        self.rc.write_text(text)
        result = self.run_script(NO_ALT_DRAG)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            result.stderr, f"could not remove the Frame mouse context from {self.rc}\n"
        )

    def with_client_bind(self, button: str, action: str) -> str:
        """The fixture with one more binding in the Client context: BUTTON, ACTION, Move."""
        client = '  <context name="Client">\n'
        self.assertEqual(self.original.count(client), 1)
        bind = (
            f'    <mousebind button="{button}" action="{action}">\n'
            '      <action name="Move"/>\n'
            "    </mousebind>\n"
        )
        text = self.original.replace(client, client + bind)
        # Where Openbox would read it: a binding of the Client context.
        (context,) = mouse_context(ET.fromstring(text), "Client")
        self.assertIn((button, action, ("Move",)), bindings(context))
        return text

    def test_58_fails_when_an_alt_drag_binding_is_in_another_context(self):
        # The Frame context's own Alt+Left drag, moved to Client: removing Frame leaves it.
        text = self.with_client_bind("A-Left", "Drag")
        self.rc.write_text(text)
        result = self.run_script(NO_ALT_DRAG)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(
            result.stderr.startswith(f"Openbox still has an Alt+drag binding in {self.rc}:\n"),
            result.stderr,
        )
        self.assertIn('<mousebind button="A-Left" action="Drag">', result.stderr)

    def test_58_fails_for_every_way_openbox_reads_an_alt_drag(self):
        # Openbox compares the action and each modifier without regard to case, reads a
        # button attribute as a space-separated list, and takes A, Alt or Mod1 for Alt.
        for button, action in (
            ("a-left", "drag"),
            ("Alt-Right", "Drag"),
            ("Mod1-Middle", "DRAG"),
            ("C-A-Left", "Drag"),
            ("A-S-Button8", "Drag"),
            ("W-Left A-Left", "Drag"),
            ("A-Left", " Drag "),
        ):
            with self.subTest(button=button, action=action):
                self.rc.write_text(self.with_client_bind(button, action))
                result = self.run_script(NO_ALT_DRAG)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Openbox still has an Alt+drag binding", result.stderr)

    def test_58_keeps_drags_without_alt_and_alt_bindings_that_are_not_drags(self):
        for button, action in (
            ("W-Left", "Drag"),
            ("S-Left", "Drag"),
            ("Left", "Drag"),
            ("A-Left", "Press"),
            ("A-Left", "Click"),
        ):
            with self.subTest(button=button, action=action):
                text = self.with_client_bind(button, action)
                result = self.run_ok(NO_ALT_DRAG, text)
                expected = self.without_frame_context(ET.fromstring(text))
                self.assertEqual(structure(ET.fromstring(result)), structure(expected))

    def test_58_fails_when_it_cannot_read_a_binding(self):
        # The check reads each <mousebind> start tag as one line, as the image writes them.
        # A tag split over lines could hide an Alt+drag, so the script must not pass it.
        bind = '<mousebind button="A-Middle" action="Drag">'
        text = self.with_client_bind("A-Middle", "Drag")
        self.assertEqual(text.count(bind), 1)
        text = text.replace(bind, '<mousebind button="A-Middle"\n              action="Drag">')
        self.rc.write_text(text)
        result = self.run_script(NO_ALT_DRAG)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            result.stderr,
            f"cannot check {self.rc} for Alt+drag bindings: a <mousebind> tag does not have "
            "its button and action on one line\n",
        )

    def test_scripts_fail_when_rc_xml_is_missing(self):
        for script in (NO_KEEPBORDER, NO_ALT_DRAG):
            with self.subTest(script=script.name):
                result = self.run_script(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.rc.exists())


if __name__ == "__main__":
    unittest.main()
