"""Tests for config/novnc/core-glyphs/make_table.py.

Run: python3 -m unittest discover -s tests
"""

import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MAKE_TABLE = REPO_ROOT / "config" / "novnc" / "core-glyphs" / "make_table.py"
COMMITTED_TABLE = REPO_ROOT / "config" / "novnc" / "core-glyphs.js"

spec = importlib.util.spec_from_file_location("make_table", MAKE_TABLE)
make_table = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_table)

TRANSPARENT = (1, 1, 1, 0)
BLACK = (0, 0, 0, 255)
WHITE = (255, 255, 255, 255)


def rgba(*pixels: tuple[int, int, int, int]) -> bytes:
    return bytes(value for pixel in pixels for value in pixel)


class GlyphRowsTests(unittest.TestCase):
    def test_classifies_the_three_core_glyph_states(self):
        data = rgba(TRANSPARENT, BLACK, WHITE, (0, 0, 0, 0), WHITE, BLACK)
        self.assertEqual(make_table.glyph_rows(data, 3, 2, "g"), [".#W", ".W#"])

    def test_rejects_pixels_a_core_glyph_cannot_have(self):
        for pixel in ((128, 128, 128, 255), (0, 0, 0, 128), (255, 255, 254, 255)):
            with self.subTest(pixel=pixel), self.assertRaises(ValueError):
                make_table.glyph_rows(rgba(BLACK, pixel), 2, 1, "g")

    def test_rejects_wrong_byte_count(self):
        with self.assertRaises(ValueError):
            make_table.glyph_rows(rgba(BLACK, WHITE), 3, 1, "g")


class BuildAndRenderTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def capture(self, name: str, index: int, keyword: str, summary: dict, data: bytes) -> None:
        with (self.dir / "glyphs.txt").open("a") as f:
            f.write(f"{name} {index} {keyword}\n")
        (self.dir / f"{name}.json").write_text(json.dumps(summary))
        (self.dir / f"{name}.rgba").write_bytes(data)

    def test_builds_entries_in_capture_order(self):
        self.capture(
            "fleur", 52, "move", {"w": 2, "h": 1, "hotx": 1, "hoty": 0}, rgba(BLACK, WHITE)
        )
        self.capture(
            "watch", 150, "wait", {"w": 1, "h": 2, "hotx": 0, "hoty": 1}, rgba(WHITE, BLACK)
        )
        table = make_table.build_table(self.dir)
        self.assertEqual([g["glyph"] for g in table], ["fleur", "watch"])
        self.assertEqual(table[0]["rows"], ["#W"])
        self.assertEqual((table[1]["hotx"], table[1]["hoty"]), (0, 1))
        self.assertEqual(table[1]["keyword"], "wait")

    def test_rejects_an_empty_capture(self):
        self.capture("left_ptr", 68, "default", {"w": 0, "h": 0, "hotx": 0, "hoty": 0}, b"")
        with self.assertRaises(ValueError):
            make_table.build_table(self.dir)

    def test_render_names_the_image_and_lists_every_row(self):
        self.capture("fleur", 52, "move", {"w": 2, "h": 2, "hotx": 1, "hoty": 1},
                     rgba(BLACK, WHITE, TRANSPARENT, BLACK))  # fmt: skip
        text = make_table.render(make_table.build_table(self.dir), "image:tag")
        self.assertIn("from image:tag; do not edit.", text)
        self.assertIn("export const CORE_GLYPHS = [", text)
        self.assertIn("glyph: 'fleur', index: 52, keyword: 'move',", text)
        self.assertIn("w: 2, h: 2, hotx: 1, hoty: 1,", text)
        self.assertEqual(re.findall(r"^ {12}'([.#W]+)',$", text, re.MULTILINE), ["#W", ".#"])


class CommittedTableTests(unittest.TestCase):
    def test_committed_table_is_well_formed(self):
        text = COMMITTED_TABLE.read_text(encoding="utf-8")
        entries = re.findall(
            r"glyph: '([a-z_]+)', index: (\d+), keyword: '([a-z-]+)',\n"
            r" +w: (\d+), h: (\d+), hotx: (\d+), hoty: (\d+),\n"
            r" +rows: \[\n((?: +'[.#W]+',\n)+) +\],",
            text,
        )
        self.assertEqual(len(entries), 11)
        for glyph, _index, _keyword, w, h, hotx, hoty, rows in entries:
            rows = re.findall(r"'([.#W]+)'", rows)
            with self.subTest(glyph=glyph):
                self.assertEqual(len(rows), int(h))
                self.assertTrue(all(len(row) == int(w) for row in rows))
                self.assertLess(int(hotx), int(w))
                self.assertLess(int(hoty), int(h))


if __name__ == "__main__":
    unittest.main()
