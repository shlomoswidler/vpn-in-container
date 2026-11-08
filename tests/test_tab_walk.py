"""Tests for tests/e2e/tab_walk.sh (the tab walk of tests/e2e/run.sh's check_tabs).

The walk runs inside the e2e test container against a real Firefox. Here it runs with sh and a
stub `xdotool` on PATH that keeps a window's tabs in a JSON file: Alt+1..8 show that tab if
there is one, Alt+9 the last tab, Ctrl+PageDown the next tab (the first after the last), and
`getwindowname` prints the shown tab's title as Firefox's window title. The stub also models
what tests/e2e/run.sh must cope with: a key Firefox handles a few reads late, and a tab that
session restore brought back, which shows the title it was saved with until it has been shown
and its page has loaded again. The script's clock is a file the stub advances (TAB_WALK_CLOCK),
so a 15 s wait takes a fraction of a second.
Run: python3 -m unittest discover -s tests
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "tests" / "e2e" / "tab_walk.sh"
WINDOW = "8388611"

# Started as `python -IS` (no site packages: a faster start, for many calls per walk). One
# word: Linux passes a shebang's arguments as a single argument, so `-I -S` would reach
# Python as "-I -S" and fail.
STUB_XDOTOOL = """\
#!{python} -IS
import json, os, sys
path = os.environ["STUB_STATE"]
with open(path) as f:
    state = json.load(f)
tabs = state["tabs"]
args = sys.argv[1:]
state["calls"].append(args)


def tick(cs):
    state["clock"] += cs


def select(index):
    lag = state.get("lag", 0)
    if lag:
        state["pending"] = [index, lag]
    else:
        show(index)


def show(index):
    state["selected"] = index
    tab = tabs[index]
    if "placeholder" in tab:
        tab.setdefault("reads_to_load", tab.get("loads_after", 0))


def title():
    tab = tabs[state["selected"]]
    if "placeholder" in tab:
        if tab.get("reads_to_load", 0) > 0:
            tab["reads_to_load"] -= 1
            return tab["placeholder"]
        if "reads_to_load" in tab:
            del tab["placeholder"]
        else:
            return tab["placeholder"]
    return tab["title"]


code = 0
if args[0] == "getwindowname":
    tick(state.get("read_cs", 10))
    if args[1] != state["window"]:
        code = 1
    else:
        pending = state.get("pending")
        if pending:
            pending[1] -= 1
            if pending[1] <= 0:
                show(pending[0])
                state["pending"] = None
        shown = title()
        suffix = " — Mozilla Firefox" + (" Private Browsing" if state.get("private") else "")
        print((shown + suffix) if shown else suffix[3:])
else:
    tick(5)
    words = list(args)
    while words:
        word = words.pop(0)
        if word == "key":
            key = words.pop(0)
            if key == "alt+9":
                select(len(tabs) - 1)
            elif key.startswith("alt+") and int(key[4:]) <= len(tabs):
                select(int(key[4:]) - 1)
            elif key == "ctrl+Next":
                select((state["selected"] + 1) % len(tabs))
        elif word == "sleep":
            tick(round(float(words.pop(0)) * 100))
        else:
            code = 2
with open(path, "w") as f:
    json.dump(state, f)
with open(os.environ["TAB_WALK_CLOCK"], "w") as f:
    f.write("%d.%02d 0.00\\n" % divmod(state["clock"], 100))
sys.exit(code)
"""


def tab(title: str, **extra) -> dict:
    return {"title": title, **extra}


def restored_tabs() -> list[dict]:
    """Tabs session restore brought back: tab 1 shows the title it was saved with, from before
    the quit, until it has been shown and its page has loaded again, here at the first read
    after it is shown."""
    return [
        tab("sw:main newnew", placeholder="sw:main oldold", loads_after=1),
        tab("sw:popup pppppp"),
        tab("e2e blank page"),
    ]


# Each walk the tests check, by name: (tabs, index of the tab shown, names, options). A
# read_cs of 500 (5 s per read) makes a failing step's 15 s wait 3 reads.
WALKS = {
    "right": ([tab("sw:main aaaaaa"), tab("sw:popup bbbbbb"), tab("e2e blank page"), tab("")],
              0, "main popup e2e-blank untitled", {}),
    "latency": ([tab("sw:a aaaaaa"), tab("sw:b bbbbbb")], 0, "a b", {"lag": 2, "read_cs": 10}),
    "late-key": ([tab("sw:a aaaaaa"), tab("sw:b bbbbbb"), tab("sw:c cccccc")], 1, "a b c",
                 {"lag": 3}),
    "wrong-last": ([tab("sw:a aaaaaa"), tab("sw:c cccccc"), tab("sw:b bbbbbb")], 0, "a b c",
                   {"read_cs": 500}),
    "wrong-first": ([tab("sw:b bbbbbb"), tab("sw:a aaaaaa"), tab("sw:c cccccc")], 0, "a b c",
                    {"read_cs": 500}),
    "missing": ([tab("sw:a aaaaaa"), tab("sw:c cccccc")], 0, "a b c", {"read_cs": 500}),
    "more-after-last": ([tab("sw:a aaaaaa"), tab("sw:b bbbbbb"), tab("sw:a cccccc"),
                         tab("sw:b dddddd")], 0, "a b", {"read_cs": 500}),
    "one-tab": ([tab("sw:main aaaaaa")], 0, "main", {"absence": "1.500"}),
    "one-tab-second": ([tab("sw:main aaaaaa"), tab("")], 0, "main", {}),
    "one-tab-wrong": ([tab("")], 0, "main", {"read_cs": 500}),
    "timeout": ([tab("sw:a aaaaaa"), tab("sw:b bbbbbb")], 0, "a x", {"read_cs": 500}),
    "private": ([tab("sw:private aaaaaa"), tab("")], 1, "private untitled", {"private": True}),
    "restored-no-earlier": (restored_tabs(), 2, "main popup e2e-blank", {"read_cs": 500}),
    "restored": (restored_tabs(), 2, "main popup e2e-blank",
                 {"earlier": ["sw:main oldold", "sw:popup qqqqqq"]}),
    "never-loads": ([tab("sw:main newnew", placeholder="sw:main oldold", loads_after=10**6),
                     tab("e2e blank page")], 1, "main e2e-blank",
                    {"earlier": ["sw:main oldold"], "read_cs": 500}),
}  # fmt: skip


def run_walk(directory: Path, tabs, selected, names, options) -> tuple:
    """Run the walk on TABS (the shown one at index SELECTED) for NAMES, with its own stub
    state in DIRECTORY. Returns (exit status, stdout lines, stderr, the stub's final state)."""
    options = dict(options)
    earlier = options.pop("earlier", ())
    absence = options.pop("absence", "1.000")
    bin_dir = directory / "bin"
    bin_dir.mkdir(parents=True)
    (bin_dir / "xdotool").write_text(STUB_XDOTOOL.replace("{python}", sys.executable))
    (bin_dir / "xdotool").chmod(0o755)
    state_file = directory / "state.json"
    clock = directory / "uptime"
    clock.write_text("1000.00 0.00\n")
    state_file.write_text(
        json.dumps(
            {"tabs": tabs, "selected": selected, "clock": 100000, "calls": [], "window": WINDOW,
             **options}
        )
    )  # fmt: skip
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "STUB_STATE": str(state_file),
        "TAB_WALK_CLOCK": str(clock),
        "EARLIER_TITLE_LIST": "\n".join(earlier),
    }
    result = subprocess.run(
        ["sh", str(SCRIPT), WINDOW, absence, *names.split()],
        env=env, capture_output=True, text=True, timeout=60, check=False,
    )  # fmt: skip
    return (
        result.returncode, result.stdout.splitlines(), result.stderr,
        json.loads(state_file.read_text()),
    )  # fmt: skip


class TabWalkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # The walks run at the same time (each one makes a few dozen stub calls and waits;
        # one after another, they took about 8 s).
        tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(tmp.cleanup)
        with ThreadPoolExecutor(max_workers=len(WALKS)) as pool:
            futures = {
                name: pool.submit(run_walk, Path(tmp.name) / name, *walk)
                for name, walk in WALKS.items()
            }
        cls.results = {name: future.result() for name, future in futures.items()}

    def walk(self, name):
        """The result of walk NAME (see WALKS): (exit status, stdout lines, stub state)."""
        status, lines, stderr, state = self.results[name]
        self.assertEqual(stderr, "", name)
        return status, lines, state

    def failure(self, lines):
        fails = [line for line in lines if line.startswith("fail ")]
        self.assertEqual(len(fails), 1, lines)
        return fails[0][len("fail ") :]

    def test_the_right_tabs_in_order_pass(self):
        status, lines, state = self.walk("right")
        self.assertEqual(status, 0, lines)
        # Alt+9, Alt+1..4, Ctrl+PageDown, Alt+4: one latency each.
        self.assertEqual(len([line for line in lines if line.startswith("latency ")]), 7)
        self.assertIn("title sw:main aaaaaa", lines)
        self.assertEqual(state["selected"], 3, "the walk ends with the last tab shown")
        keys = [call[1] for call in state["calls"] if call[0] == "key"]
        self.assertEqual(keys, ["alt+9", "alt+1", "alt+2", "alt+3", "alt+4", "ctrl+Next", "alt+4"])

    def test_latency_is_the_time_from_the_key_to_the_title(self):
        # Each read advances the stub's clock by 0.1 s and each key by 0.05 s; Firefox shows
        # the new tab at the 2nd read after a key: each step takes 0.25 s.
        status, lines, _ = self.walk("latency")
        self.assertEqual(status, 0, lines)
        latencies = {int(line.split()[1]) for line in lines if line.startswith("latency ")}
        self.assertEqual(latencies, {250})

    def test_a_late_key_is_waited_for(self):
        # The title changes only some reads after the key: the step waits for it.
        status, lines, _ = self.walk("late-key")
        self.assertEqual(status, 0, lines)

    def test_a_wrong_order_fails_at_the_first_wrong_tab(self):
        status, lines, _ = self.walk("wrong-last")
        self.assertEqual(status, 1)
        # Alt+9 shows b, not c.
        self.assertEqual(self.failure(lines), "the last tab is 'sw:b bbbbbb', not c")
        status, lines, _ = self.walk("wrong-first")
        self.assertEqual(status, 1)
        self.assertEqual(self.failure(lines), "tab 1 is 'sw:b bbbbbb', not a")

    def test_a_missing_tab_fails(self):
        status, lines, _ = self.walk("missing")
        self.assertEqual(status, 1)
        self.assertEqual(self.failure(lines), "tab 2 is 'sw:c cccccc', not b")

    def test_more_tabs_after_the_last_fail(self):
        # Alt+1..2 and Alt+9 all match a b, but tabs 3 and 4 are more of the same pages:
        # Ctrl+PageDown from tab 2 shows tab 3, a page "a" with another load's title.
        status, lines, _ = self.walk("more-after-last")
        self.assertEqual(status, 1)
        self.assertEqual(self.failure(lines), "after tab 2 comes 'sw:a cccccc', not tab 1")

    def test_one_tab_passes_and_a_second_tab_fails(self):
        status, lines, state = self.walk("one-tab")
        self.assertEqual(status, 0, lines)
        # Ctrl+PageDown, then the absence wait, in one xdotool call.
        self.assertIn(["key", "ctrl+Next", "sleep", "1.500"], state["calls"])
        status, lines, _ = self.walk("one-tab-second")
        self.assertEqual(status, 1)
        self.assertEqual(self.failure(lines), "a second tab exists: ''")
        status, lines, _ = self.walk("one-tab-wrong")
        self.assertEqual(status, 1)
        self.assertEqual(self.failure(lines), "the window shows '', not main")

    def test_the_wait_for_a_title_ends_after_15_s(self):
        status, lines, state = self.walk("timeout")
        self.assertEqual(status, 1)
        self.assertEqual(self.failure(lines), "the last tab is 'sw:b bbbbbb', not x")
        reads = [call for call in state["calls"] if call[0] == "getwindowname"]
        # 15 s at 5 s per read: 3 reads (the first shows b), then the one for the message.
        self.assertEqual(len(reads), 4)

    def test_private_window_titles(self):
        status, lines, _ = self.walk("private")
        self.assertEqual(status, 0, lines)

    def test_a_restored_tab_is_read_only_once_its_page_has_loaded(self):
        # A walk that took tab 1's saved title fails at the wrap, where tab 1 shows its new
        # title (docs/agents_output/debugging/e2e-off-ctrl-q.md).
        status, lines, _ = self.walk("restored-no-earlier")
        self.assertEqual(status, 1, "without the earlier titles the walk takes the saved one")
        self.assertEqual(self.failure(lines), "after tab 3 comes 'sw:main newnew', not tab 1")
        status, lines, _ = self.walk("restored")
        self.assertEqual(status, 0, lines)
        self.assertIn("title sw:main newnew", lines)
        self.assertNotIn("title sw:main oldold", lines)

    def test_a_tab_that_never_loads_again_fails(self):
        status, lines, _ = self.walk("never-loads")
        self.assertEqual(status, 1)
        self.assertEqual(self.failure(lines), "tab 1 is 'sw:main oldold', not main")


if __name__ == "__main__":
    unittest.main()
