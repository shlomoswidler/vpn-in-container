"""Static tests of the single-window settings in config/firefox-chrome/userChrome.css,
config/firefox-profile/customKeys.json and config/firefox-autoconfig/single-window.cfg.

Firefox keeps at most one normal and one private window here: a new window's tabs move into
the open window of the same kind (single-window.cfg), and the controls that open a second
normal window or quit are hidden (userChrome.css) or cleared (customKeys.json). Private
windows stay available as in Firefox itself: their menu items and Ctrl+Shift+P work. Close
Window (Ctrl+Shift+W and its menu items) stays: single-window.cfg disables it on the last
window, and it adds a Window menu and Ctrl+` to switch windows.
tests/e2e/run.sh checks the behavior in a real Firefox.
Run: python3 -m unittest discover -s tests
"""

import json
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
USER_CHROME = REPO_ROOT / "config" / "firefox-chrome" / "userChrome.css"
CUSTOM_KEYS = REPO_ROOT / "config" / "firefox-profile" / "customKeys.json"
SINGLE_WINDOW = REPO_ROOT / "config" / "firefox-autoconfig" / "single-window.cfg"

# Menu items that open a second normal window or quit (which stops the container): app menu,
# File menu, tab, link and bookmarks context menus.
HIDDEN_ITEMS = {
    "appMenu-new-window-button2",
    "menu_newNavigator",
    "context_openTabInWindow",
    "context-openlink",
    "placesContext_open:newwindow",
    "appMenu-quit-button2",
    "menu_FileQuitItem",
}
# Items that must stay: the private-window items (app menu, File menu, link and bookmarks
# context menus) and File > Close Window (disabled on the last window by single-window.cfg).
SHOWN_ITEMS = {
    "appMenu-new-private-window-button2",
    "menu_newPrivateWindow",
    "context-openlinkprivate",
    "placesContext_open:newprivatewindow",
    "menu_closeWindow",
}
# Shortcuts cleared: Ctrl+N and Ctrl+Shift+N (reopen a closed window). Ctrl+Shift+P
# (key_privatebrowsing) and Ctrl+Shift+W (key_closeWindow, disabled with its command on the last
# window) stay. Ctrl+Q stays too: the image's shutdown script sends it.
CLEARED_KEYS = {"key_newNavigator", "key_undoCloseWindow"}


def hidden_ids(css: str) -> set[str]:
    """The element ids in the selector list of each `display: none` rule, unescaped."""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.DOTALL)
    ids = set()
    for selectors, body in re.findall(r"([^{}]+)\{([^}]*)\}", css):
        if re.search(r"display\s*:\s*none", body):
            for selector in selectors.split(","):
                match = re.fullmatch(r"\s*#((?:[\w-]|\\.)+)\s*", selector)
                if match:
                    ids.add(re.sub(r"\\(.)", r"\1", match.group(1)))
    return ids


class SingleWindowSettingsTests(unittest.TestCase):
    def test_the_rule_parser_reads_escaped_ids(self):
        css = "/* #not-this { display: none } */\n#a,\n#b\\:c {\n  display: none !important;\n}"
        self.assertEqual(hidden_ids(css), {"a", "b:c"})

    def test_hides_the_items_that_open_a_normal_window_or_quit(self):
        self.assertEqual(hidden_ids(USER_CHROME.read_text()), HIDDEN_ITEMS)

    def test_private_window_and_close_window_items_are_not_hidden(self):
        self.assertEqual(hidden_ids(USER_CHROME.read_text()) & SHOWN_ITEMS, set())

    def test_clears_exactly_the_new_window_keys(self):
        keys = json.loads(CUSTOM_KEYS.read_text())
        self.assertEqual(set(keys), CLEARED_KEYS)
        for key, value in keys.items():
            with self.subTest(key=key):
                self.assertEqual(value, {}, "an empty entry clears the shortcut")

    def test_single_window_cfg_never_closes_a_window(self):
        # A window disappears only when adoptTab has moved its last tab away, or when the user
        # closes it. Code that closes a window could close one that still has tabs.
        code = re.sub(r"//[^\n]*", "", SINGLE_WINDOW.read_text())
        self.assertNotRegex(code, r"\.close\s*\(")
        self.assertNotRegex(code, r"closeWindow\s*\(")
        self.assertNotRegex(code, r"doCommand")

    def test_single_window_cfg_enables_close_window_only_with_another_window(self):
        # Close Window is enabled or disabled through its command, from the window count,
        # whenever a window opens or closes; never enabled for good.
        code = re.sub(r"//[^\n]*", "", SINGLE_WINDOW.read_text())
        self.assertRegex(
            code, r'goSetCommandEnabled\(\s*"cmd_closeWindow",\s*windows\.length > 1\)'
        )
        self.assertIn('"browser-delayed-startup-finished"', code)
        self.assertIn('"domwindowclosed"', code)


if __name__ == "__main__":
    unittest.main()
