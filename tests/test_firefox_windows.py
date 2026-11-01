"""Static tests of the single-window settings in config/firefox-chrome/userChrome.css,
config/firefox-profile/customKeys.json and config/firefox-autoconfig/single-window.cfg.

Firefox keeps at most one normal and one private window here: a new window's tabs move into
the open window of the same kind (single-window.cfg), and the controls that open a second
normal window or quit are hidden (userChrome.css) or cleared (customKeys.json). Private
windows stay available as in Firefox itself: their menu items and Ctrl+Shift+P work.
single-window.cfg adds Quit & Restart (Ctrl+Q, the File and main menus), which asks first, and
Ctrl+Alt+Shift+Q, which quits without asking for the container's shutdown script
(config/firefox-services/kill). Without permanent private browsing it adds a Window menu and
Ctrl+` to switch windows; with it, there is one window, and it removes Close Window instead.
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
SHUTDOWN_SCRIPT = REPO_ROOT / "config" / "firefox-services" / "kill"

# Menu items that open a second normal window (app menu, File menu, tab, link and bookmarks
# context menus), and Firefox's own Quit items (single-window.cfg adds Quit & Restart instead).
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
# context menus) and File > Close Window (single-window.cfg hides it only with permanent private
# browsing).
SHOWN_ITEMS = {
    "appMenu-new-private-window-button2",
    "menu_newPrivateWindow",
    "context-openlinkprivate",
    "placesContext_open:newprivatewindow",
    "menu_closeWindow",
}
# Shortcuts cleared: Ctrl+N and Ctrl+Shift+N (reopen a closed window), and Firefox's own Ctrl+Q
# (single-window.cfg's Ctrl+Q is Quit & Restart). Ctrl+Shift+P (key_privatebrowsing) and
# Ctrl+Shift+W (key_closeWindow, disabled with its command with permanent private browsing) stay.
CLEARED_KEYS = {"key_newNavigator", "key_undoCloseWindow", "key_quitApplication"}


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

    def test_tabs_move_once_the_session_store_has_their_pages(self):
        # adoptTab leaves the moved page reporting to the session store under the closed
        # window's key, so a tab moved before its page was saved (a shift-clicked link's new
        # window) would not be reopened after Quit & Restart. A later window's tabs move only
        # once each has a session-history entry (or its load stopped) and the window is flushed.
        code = re.sub(r"//[^\n]*", "", SINGLE_WINDOW.read_text())
        waits = re.search(r"const pagesSaved = .*?\n    \}\)\.then\(.*?\);\n", code, re.DOTALL)
        self.assertIsNotNone(waits)
        body = waits.group(0)
        self.assertIn("history.count > 0", body)
        self.assertRegex(body, r"\(flags & STATE_STOP\) && \(flags & STATE_IS_NETWORK\)")
        self.assertIn("TabStateFlusher.flushWindow(win)", body)
        self.assertEqual(code.count("adoptTab("), 1)
        self.assertLess(code.index("pagesSaved(newWindow).then("), code.index("adoptTab("))

    def test_private_only_removes_close_window_and_adds_no_window_menu(self):
        # With permanent private browsing (read per window: the image writes the pref into
        # prefs.js, which Firefox reads after autoconfig), Close Window's menu item is hidden
        # and its command (Ctrl+Shift+W) disabled; otherwise the Window menu and Ctrl+` are
        # added. Nothing else depends on the setting.
        code = re.sub(r"//[^\n]*", "", SINGLE_WINDOW.read_text())
        self.assertIn("PrivateBrowsingUtils.permanentPrivateBrowsing;", code)
        self.assertRegex(
            code,
            r"if \(privateOnly\(\)\) \{\s*removeCloseWindow\(newWindow\);\s*\} else "
            r"\{\s*addWindowControls\(newWindow\);\s*\}",
        )
        self.assertRegex(code, r'getElementById\("menu_closeWindow"\)\.hidden = true;')
        self.assertRegex(code, r'goSetCommandEnabled\("cmd_closeWindow", false\)')
        self.assertIn('"browser-delayed-startup-finished"', code)

    def test_quit_and_restart_asks_before_quitting(self):
        # Ctrl+Q and both menu items run quitAndRestart, which returns before Firefox's own
        # Quit unless the first button (Quit & Restart) was chosen.
        code = re.sub(r"//[^\n]*", "", SINGLE_WINDOW.read_text())
        body = re.search(r"const quitAndRestart = .*?\n    \};", code, re.DOTALL).group(0)
        self.assertLess(body.index("confirmEx("), body.index("goQuitApplication("))
        self.assertRegex(body, r"confirmEx\([^;]*\) !== 0\) \{\s*return;")
        self.assertRegex(
            code,
            r'\["single-window-key-quit", "Q", "accel", \(event\) => '
            r"quitAndRestart\(win, event\)\]",
        )
        # Ctrl+Q and File > Quit & Restart ask at once; the main menu's item asks once the
        # menu has closed (test_main_menu_closes_before_asking).
        self.assertEqual(code.count("(event) => quitAndRestart(win, event)"), 2)
        self.assertEqual(code.count("quitAndRestart(win, event);"), 2)

    def test_quit_and_restart_button_label_shows_its_ampersand(self):
        # In a prompt button's label "&" marks the access key and "&&" is a plain "&": a single
        # "&" would show "Quit Restart" with Space as its access key.
        code = re.sub(r"//[^\n]*", "", SINGLE_WINDOW.read_text())
        body = re.search(r"const quitAndRestart = .*?\n    \};", code, re.DOTALL).group(0)
        self.assertRegex(
            body, r'confirmEx\(win, "Quit & Restart", text, flags, "Quit && Restart", null,'
        )

    def test_main_menu_closes_before_asking(self):
        # The main menu (a panel) stays open while its item's command runs, and while it is
        # open its capturing keydown listener takes Return for the selected item: a question
        # asked from the command would get its own item chosen again instead of an answer.
        # So the item hides the panel and asks on the panel's own popuphidden.
        code = re.sub(r"//[^\n]*", "", SINGLE_WINDOW.read_text())
        body = re.search(r"const addAppMenuItem = .*?\n    \};", code, re.DOTALL).group(0)
        handler = re.search(
            r'item\.addEventListener\("command", \(event\) => \{.*?\n        \}\);', body, re.DOTALL
        ).group(0)
        self.assertIn("const panel = win.PanelUI.panel;", handler)
        self.assertRegex(
            handler,
            r'if \(panel\.state === "closed" \|\| doc\.documentElement\.hasAttribute\('
            r'"customizing"\)\) \{\s*quitAndRestart\(win, event\);\s*return;\s*\}',
        )
        self.assertRegex(
            handler,
            r"const onHidden = \(hidden\) => \{\s*if \(hidden\.target === panel\) \{\s*"
            r'panel\.removeEventListener\("popuphidden", onHidden\);\s*'
            r"quitAndRestart\(win, event\);",
        )
        self.assertLess(
            handler.index('panel.addEventListener("popuphidden", onHidden);'),
            handler.index("win.PanelUI.hide();"),
        )

    def test_firefox_keys_stay_before_devtools_keys(self):
        # Of two keysets with the same key, the one bound first gets it, and DevTools' keyset
        # also has Ctrl+Shift+W (its DOM panel). Because customKeys.json is not empty, Firefox
        # re-binds mainKeyset once it has read the file, which in a process's first window can
        # come after DevTools added its keyset: Ctrl+Shift+W then did nothing
        # (docs/agents_output/debugging/ctrl-shift-w-intermittent.md). Every browser window
        # re-binds DevTools' keyset (inserted before mainKeyset, as DevTools does) now and after
        # each re-bind of mainKeyset, from the start of the window's delayed startup.
        self.assertNotEqual(json.loads(CUSTOM_KEYS.read_text()), {})
        code = re.sub(r"//[^\n]*", "", SINGLE_WINDOW.read_text())
        body = re.search(r"const keepMainKeysFirst = .*?\n    \};", code, re.DOTALL)
        self.assertIsNotNone(body)
        body = body.group(0)
        self.assertIn('doc.getElementById("mainKeyset")', body)
        self.assertIn('doc.getElementById("devtoolsKeyset")', body)
        self.assertIn("main.parentNode.insertBefore(devtools, main);", body)
        self.assertRegex(
            body,
            r"rebindDevTools\(\);\s*new win\.MutationObserver\(\(mutations\) => \{\s*"
            r"if \(mutations\.some\(\(mutation\) => "
            r"Array\.from\(mutation\.addedNodes\)\.includes\(main\)\)\) \{\s*rebindDevTools\(\);",
        )
        self.assertIn(".observe(main.parentNode, { childList: true });", body)
        self.assertRegex(
            code,
            r"Services\.obs\.addObserver\(\(newWindow\) => \{\s*keepMainKeysFirst\(newWindow\);",
        )

    def test_shutdown_key_is_the_one_the_shutdown_script_presses(self):
        # The container's shutdown script must press the key that quits without asking, or
        # every `docker stop` would open the Quit & Restart dialog and kill Firefox after it.
        code = re.sub(r"//[^\n]*", "", SINGLE_WINDOW.read_text())
        self.assertRegex(
            code,
            r'\["single-window-key-shutdown", "Q", "accel,alt,shift",\s*'
            r"\(event\) => win\.goQuitApplication\(event\)\]",
        )
        script = re.sub(r"#[^\n]*", "", SHUTDOWN_SCRIPT.read_text())
        self.assertEqual(
            re.findall(r'xdotool key "([^"]+)"', script), ["Escape", "ctrl+alt+shift+q"]
        )


if __name__ == "__main__":
    unittest.main()
